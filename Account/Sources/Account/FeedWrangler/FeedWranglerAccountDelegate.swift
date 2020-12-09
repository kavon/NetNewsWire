//
//  FeedWranglerAccountDelegate.swift
//  Account
//
//  Created by Jonathan Bennett on 2019-08-29.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Articles
import RSCore
import RSParser
import RSWeb
import SyncDatabase
import os.log
import Secrets

final class FeedWranglerAccountDelegate: AccountDelegate {
	
	var behaviors: AccountBehaviors = [.disallowFolderManagement]
	
	var isOPMLImportInProgress = false
	var server: String? = FeedWranglerConfig.clientPath
	var credentials: Credentials? {
		didSet {
			caller.credentials = credentials
		}
	}
	
	var accountMetadata: AccountMetadata?
	var refreshProgress = DownloadProgress(numberOfTasks: 0)
	
	private let caller: FeedWranglerAPICaller
	private let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "Feed Wrangler")
	private let database: SyncDatabase
	
	init(dataFolder: String, transport: Transport?) {
		if let transport = transport {
			caller = FeedWranglerAPICaller(transport: transport)
		} else {
			let sessionConfiguration = URLSessionConfiguration.default
			sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
			sessionConfiguration.timeoutIntervalForRequest = 60.0
			sessionConfiguration.httpShouldSetCookies = false
			sessionConfiguration.httpCookieAcceptPolicy = .never
			sessionConfiguration.httpMaximumConnectionsPerHost = 1
			sessionConfiguration.httpCookieStorage = nil
			sessionConfiguration.urlCache = nil
			
			if let userAgentHeaders = UserAgent.headers() {
				sessionConfiguration.httpAdditionalHeaders = userAgentHeaders
			}
			
			let session = URLSession(configuration: sessionConfiguration)
			caller = FeedWranglerAPICaller(transport: session)
		}
		
		database = SyncDatabase(databaseFilePath: dataFolder.appending("/DB.sqlite3"))
	}
	
	func accountWillBeDeleted(_ account: Account) {
		caller.logout() { _ in }
	}
	
	func receiveRemoteNotification(for account: Account, userInfo: [AnyHashable : Any]) async {
		return
	}
	
	func refreshAll(for account: Account) async throws {
		refreshProgress.addToNumberOfTasksAndRemaining(6)
		
		self.refreshCredentials(for: account)
		self.refreshProgress.completeTask()
		
		await try self.refreshSubscriptions(for: account)
		self.refreshProgress.completeTask()

		await try self.sendArticleStatus(for: account)
		self.refreshProgress.completeTask()
			
		await self.refreshArticleStatus(for: account)
		self.refreshProgress.completeTask()

		await try self.refreshArticles(for: account)
		self.refreshProgress.completeTask()
		
		// TODO: keep going!
		self.refreshMissingArticles(for: account) { result in
			self.refreshProgress.completeTask()
			
			switch result {
			case .success:
				DispatchQueue.main.async {
					completion(.success(()))
				}
			
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	// TODO: revisit this once we've settled on global actor design.
	// asyncronously performs an operation on DispatchQueue.main
	@MainActor private func onMainActor(_ operation : () async -> Void ) async {
		await operation()
	}
	
	func refreshCredentials(for account: Account) { // NOTE: the completion handler seems pointless at the moment.
		os_log(.debug, log: log, "Refreshing credentials...")
		// MARK: TODO
		credentials = try? account.retrieveCredentials(type: .feedWranglerToken)
	}
	
	func refreshSubscriptions(for account: Account) async throws {
		os_log(.debug, log: log, "Refreshing subscriptions...")
		do {
			let subscriptions = await try caller.retrieveSubscriptions()
			self.syncFeeds(account, subscriptions)
		} catch let error {
			os_log(.debug, log: self.log, "Failed to refresh subscriptions: %@", error.localizedDescription)
			throw error
		}
	}
	
	func refreshArticles(for account: Account, page: Int = 0) async throws {
		os_log(.debug, log: log, "Refreshing articles, page: %d...", page)
		
		let items = await try caller.retrieveFeedItems(page: page)
		await self.syncFeedItems(account, items)
		if items.count == 0 {
			return
		} else {
			return await try self.refreshArticles(for: account, page: (page + 1))
		}
	}
	
	func refreshMissingArticles(for account: Account, completion: @escaping ((Result<Void, Error>)-> Void)) {
		account.fetchArticleIDsForStatusesWithoutArticlesNewerThanCutoffDate { articleIDsResult in

			func process(_ fetchedArticleIDs: Set<String>) {
				os_log(.debug, log: self.log, "Refreshing missing articles...")
				let group = DispatchGroup()

				let articleIDs = Array(fetchedArticleIDs)
				let chunkedArticleIDs = articleIDs.chunked(into: 100)

				for chunk in chunkedArticleIDs {
					group.enter()
					self.caller.retrieveEntries(articleIDs: chunk) { result in
						switch result {
						case .success(let entries):
							self.syncFeedItems(account, entries) {
								group.leave()
							}

						case .failure(let error):
							os_log(.error, log: self.log, "Refresh missing articles failed: %@", error.localizedDescription)
							group.leave()
						}
					}
				}

				group.notify(queue: DispatchQueue.main) {
					self.refreshProgress.completeTask()
					os_log(.debug, log: self.log, "Done refreshing missing articles.")
					completion(.success(()))
				}
			}

			switch articleIDsResult {
			case .success(let articleIDs):
				process(articleIDs)
			case .failure(let databaseError):
				self.refreshProgress.completeTask()
				completion(.failure(databaseError))
			}
		}
	}
	
	func sendArticleStatus(for account: Account) async throws {
		os_log(.debug, log: log, "Sending article status...")

		let syncStatuses = await try database.selectForProcessing()
		let articleStatuses = Dictionary(grouping: syncStatuses, by: { $0.articleID })
		
		// NOTE: Dictionary.forEach is sequential, so the previous DispatchGroup usage here was not needed
		// and could be simplified as performing the logging operation on the main dispatch queue.
		articleStatuses.forEach { articleID, statuses in
			await self.caller.updateArticleStatus(articleID, statuses)
		}

		await self.onMainActor {
			os_log(.debug, log: self.log, "Done sending article statuses.")
		}
	}
	
	func refreshArticleStatus(for account: Account) async {
		os_log(.debug, log: log, "Refreshing article status...")
		
		do {
			let items = await try caller.retrieveAllUnreadFeedItems()
			self.syncArticleReadState(account, items)
		} catch let error {
			os_log(.info, log: self.log, "Retrieving unread entries failed: %@.", error.localizedDescription)
		}
		
		// starred
		do {
			let items = await try caller.retrieveAllStarredFeedItems()
			self.syncArticleStarredState(account, items)
		} catch let error {
			os_log(.info, log: self.log, "Retrieving starred entries failed: %@.", error.localizedDescription)
		}
		
		await self.onMainActor {
			os_log(.debug, log: self.log, "Done refreshing article statuses.")
		}
	}
	
	func importOPML(for account: Account, opmlFile: URL, completion: @escaping (Result<Void, Error>) -> Void) {
		fatalError()
	}
	
	func createFolder(for account: Account, name: String, completion: @escaping (Result<Folder, Error>) -> Void) {
		fatalError()
	}
	
	func renameFolder(for account: Account, with folder: Folder, to name: String, completion: @escaping (Result<Void, Error>) -> Void) {
		fatalError()
	}
	
	func removeFolder(for account: Account, with folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
		fatalError()
	}
	
	func createWebFeed(for account: Account, url: String, name: String?, container: Container, completion: @escaping (Result<WebFeed, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(2)
		
		self.refreshCredentials(for: account) {
			self.refreshProgress.completeTask()
			self.caller.addSubscription(url: url) { result in
				self.refreshProgress.completeTask()
				
				switch result {
				case .success(let subscription):
					self.addFeedWranglerSubscription(account: account, subscription: subscription, name: name, container: container, completion: completion)
						
				case .failure(let error):
					DispatchQueue.main.async {
						completion(.failure(error))
					}
				}
			}
		}
	}
	
	private func addFeedWranglerSubscription(account: Account, subscription sub: FeedWranglerSubscription, name: String?, container: Container, completion: @escaping (Result<WebFeed, Error>) -> Void) {
		DispatchQueue.main.async {
			let feed = account.createWebFeed(with: sub.title, url: sub.feedURL, webFeedID: String(sub.feedID), homePageURL: sub.siteURL)
			
			account.addWebFeed(feed, to: container) { result in
				switch result {
				case .success:
					if let name = name {
						account.renameWebFeed(feed, to: name) { result in
							switch result {
							case .success:
								self.initialFeedDownload(account: account, feed: feed, completion: completion)
								
							case .failure(let error):
								completion(.failure(error))
							}
						}
					} else {
						self.initialFeedDownload(account: account, feed: feed, completion: completion)
					}
					
				case .failure(let error):
					completion(.failure(error))
				}
			}
		}
	}
	
	private func initialFeedDownload(account: Account, feed: WebFeed, completion: @escaping (Result<WebFeed, Error>) -> Void) {
		
		self.caller.retrieveFeedItems(page: 0, feed: feed) { results in
			switch results {
			case .success(let entries):
				self.syncFeedItems(account, entries) {
					DispatchQueue.main.async {
						completion(.success(feed))
					}
				}
				
			case .failure(let error):
				DispatchQueue.main.async {
					completion(.failure(error))
				}
			}
		}
	}
	
	func renameWebFeed(for account: Account, with feed: WebFeed, to name: String, completion: @escaping (Result<Void, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(2)
		
		self.refreshCredentials(for: account) {
			self.refreshProgress.completeTask()
			self.caller.renameSubscription(feedID: feed.webFeedID, newName: name) { result in
				self.refreshProgress.completeTask()
				
				switch result {
				case .success:
					DispatchQueue.main.async {
						feed.editedName = name
						completion(.success(()))
					}
					
				case .failure(let error):
					DispatchQueue.main.async {
						let wrappedError = AccountError.wrappedError(error: error, account: account)
						completion(.failure(wrappedError))
					}
				}
			}
		}
	}
	
	func addWebFeed(for account: Account, with feed: WebFeed, to container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		// just add to account, folders are not supported
		DispatchQueue.main.async {
			account.addFeedIfNotInAnyFolder(feed)
			completion(.success(()))
		}
	}
	
	func removeWebFeed(for account: Account, with feed: WebFeed, from container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(2)
		
		self.refreshCredentials(for: account) {
			self.refreshProgress.completeTask()
			self.caller.removeSubscription(feedID: feed.webFeedID) { result in
				self.refreshProgress.completeTask()
				
				switch result {
				case .success:
					DispatchQueue.main.async {
						account.clearWebFeedMetadata(feed)
						account.removeWebFeed(feed)
						completion(.success(()))
					}
					
				case .failure(let error):
					DispatchQueue.main.async {
						let wrappedError = AccountError.wrappedError(error: error, account: account)
						completion(.failure(wrappedError))
					}
				}
			}
		}
	}
	
	func moveWebFeed(for account: Account, with feed: WebFeed, from: Container, to: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		fatalError()
	}
	
	func restoreWebFeed(for account: Account, feed: WebFeed, container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		fatalError()
	}
	
	func restoreFolder(for account: Account, folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
		fatalError()
	}
	
	func markArticles(for account: Account, articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool) {
		account.update(articles, statusKey: statusKey, flag: flag) { result in
			switch result {
			case .success(let articles):
				let syncStatuses = articles.map { article in
					return SyncStatus(articleID: article.articleID, key: SyncStatus.Key(statusKey), flag: flag)
				}

				self.database.insertStatuses(syncStatuses) { _ in
					self.database.selectPendingCount { result in
						if let count = try? result.get(), count > 100 {
							self.sendArticleStatus(for: account) { _ in }
						}
					}
				}
			case .failure(let error):
				os_log(.error, log: self.log, "Error marking article status: %@", error.localizedDescription)
			}
		}
	}

	func accountDidInitialize(_ account: Account) {
		credentials = try? account.retrieveCredentials(type: .feedWranglerToken)
	}
	
	static func validateCredentials(transport: Transport, credentials: Credentials, endpoint: URL? = nil, completion: @escaping (Result<Credentials?, Error>) -> Void) {
		let caller = FeedWranglerAPICaller(transport: transport)
		caller.credentials = credentials
		caller.validateCredentials() { result in
			DispatchQueue.main.async {
				completion(result)
			}
		}
	}

	// MARK: Suspend and Resume (for iOS)

	/// Suspend all network activity
	func suspendNetwork() {
		caller.cancelAll()
	}
	
	/// Suspend the SQLLite databases
	func suspendDatabase() {
		database.suspend()
	}
	
	/// Make sure no SQLite databases are open and we are ready to issue network requests.
	func resume() {
		database.resume()
	}
}

// MARK: Private
private extension FeedWranglerAccountDelegate {
	
	func syncFeeds(_ account: Account, _ subscriptions: [FeedWranglerSubscription]) {
		assert(Thread.isMainThread)
		let feedIds = subscriptions.map { String($0.feedID) }
		
		let feedsToRemove = account.topLevelWebFeeds.filter { !feedIds.contains($0.webFeedID) }
		account.removeFeeds(feedsToRemove)

		var subscriptionsToAdd = Set<FeedWranglerSubscription>()
		subscriptions.forEach { subscription in
			let subscriptionId = String(subscription.feedID)
			
			if let feed = account.existingWebFeed(withWebFeedID: subscriptionId) {
				feed.name = subscription.title
				feed.editedName = nil
				feed.homePageURL = subscription.siteURL
				feed.externalID = nil // MARK: TODO What should this be?
			} else {
				subscriptionsToAdd.insert(subscription)
			}
		}
		
		subscriptionsToAdd.forEach { subscription in
			let feedId = String(subscription.feedID)
			let feed = account.createWebFeed(with: subscription.title, url: subscription.feedURL, webFeedID: feedId, homePageURL: subscription.siteURL)
			feed.externalID = nil
			account.addWebFeed(feed)
		}
	}
	
	func syncFeedItems(_ account: Account, _ feedItems: [FeedWranglerFeedItem]) async {
		let parsedItems = feedItems.map { (item: FeedWranglerFeedItem) -> ParsedItem in
			let itemID = String(item.feedItemID)
			// let authors = ...
			let parsedItem = ParsedItem(syncServiceID: itemID, uniqueID: itemID, feedURL: String(item.feedID), url: nil, externalURL: item.url, title: item.title, language: nil, contentHTML: item.body, contentText: nil, summary: nil, imageURL: nil, bannerImageURL: nil, datePublished: item.publishedDate, dateModified: item.updatedDate, authors: nil, tags: nil, attachments: nil)
			
			return parsedItem
		}
		
		let feedIDsAndItems = Dictionary(grouping: parsedItems, by: { $0.feedURL }).mapValues { Set($0) }
		await try? account.update(webFeedIDsAndItems: feedIDsAndItems, defaultRead: true)
	}
	
	func syncArticleReadState(_ account: Account, _ unreadFeedItems: [FeedWranglerFeedItem]) {
		let unreadServerItemIDs = Set(unreadFeedItems.map { String($0.feedItemID) })
		account.fetchUnreadArticleIDs { articleIDsResult in
			guard let unreadLocalItemIDs = try? articleIDsResult.get() else {
				return
			}
			account.markAsUnread(unreadServerItemIDs)

			let readItemIDs = unreadLocalItemIDs.subtracting(unreadServerItemIDs)
			account.markAsRead(readItemIDs)
		}
	}
	
	func syncArticleStarredState(_ account: Account, _ starredFeedItems: [FeedWranglerFeedItem]) {
		let starredServerItemIDs = Set(starredFeedItems.map { String($0.feedItemID) })
		account.fetchStarredArticleIDs { articleIDsResult in
			guard let starredLocalItemIDs = try? articleIDsResult.get() else {
				return
			}

			account.markAsStarred(starredServerItemIDs)

			let unstarredItemIDs = starredLocalItemIDs.subtracting(starredServerItemIDs)
			account.markAsUnstarred(unstarredItemIDs)
		}
	}
	
	func syncArticleState(_ account: Account, key: ArticleStatus.Key, flag: Bool, serverFeedItems: [FeedWranglerFeedItem]) {
		let _ /*serverFeedItemIDs*/ = serverFeedItems.map { String($0.feedID) }
		
		// todo generalize this logic
	}
}
