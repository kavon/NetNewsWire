//
//  AccountDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/16/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import Articles
import RSWeb
import Secrets

protocol AccountDelegate {

	var behaviors: AccountBehaviors { get }

	var isOPMLImportInProgress: Bool { get }
	
	var server: String? { get }
	var credentials: Credentials? { get set }
	var accountMetadata: AccountMetadata? { get set }
	
	var refreshProgress: DownloadProgress { get }

	func receiveRemoteNotification(for account: Account, userInfo: [AnyHashable : Any]) async

	func refreshAll(for account: Account) async throws
	func sendArticleStatus(for account: Account) async throws
	func refreshArticleStatus(for account: Account) async throws
	
	func importOPML(for account:Account, opmlFile: URL) async throws
	
	func createFolder(for account: Account, name: String) async throws -> Folder
	func renameFolder(for account: Account, with folder: Folder, to name: String) async throws
	func removeFolder(for account: Account, with folder: Folder) async throws

	func createWebFeed(for account: Account, url: String, name: String?, container: Container) async throws -> WebFeed
	func renameWebFeed(for account: Account, with feed: WebFeed, to name: String) async throws
	func addWebFeed(for account: Account, with: WebFeed, to container: Container) async throws
	func removeWebFeed(for account: Account, with feed: WebFeed, from container: Container) async throws
	func moveWebFeed(for account: Account, with feed: WebFeed, from: Container, to: Container) async throws

	func restoreWebFeed(for account: Account, feed: WebFeed, container: Container) async throws
	func restoreFolder(for account: Account, folder: Folder) async throws

	func markArticles(for account: Account, articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool)

	// Called at the end of account’s init method.
	func accountDidInitialize(_ account: Account)
	
	func accountWillBeDeleted(_ account: Account)

	static func validateCredentials(transport: Transport, credentials: Credentials, endpoint: URL?) async throws -> Credentials?

	/// Suspend all network activity
	func suspendNetwork()
	
	/// Suspend the SQLite databases
	func suspendDatabase()
	
	/// Make sure no SQLite databases are open and we are ready to issue network requests.
	func resume()
}
