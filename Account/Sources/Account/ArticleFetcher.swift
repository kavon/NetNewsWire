//
//  ArticleFetcher.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/4/18.
//  Copyright © 2018 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import Articles
import ArticlesDatabase

public protocol ArticleFetcher {

	func fetchArticles() throws -> Set<Article>
	func fetchArticlesAsync() async -> ArticleSetResult
	func fetchUnreadArticles() throws -> Set<Article>
	func fetchUnreadArticlesAsync() async -> ArticleSetResult
}

extension WebFeed: ArticleFetcher {
	
	public func fetchArticles() throws -> Set<Article> {
		return try account?.fetchArticles(.webFeed(self)) ?? Set<Article>()
	}

	public func fetchArticlesAsync() async -> ArticleSetResult {
		guard let account = account else {
			assertionFailure("Expected feed.account, but got nil.")
			return .success(Set<Article>())
		}
		return await account.fetchArticlesAsync(.webFeed(self))
	}

	public func fetchUnreadArticles() throws -> Set<Article> {
		return try fetchArticles().unreadArticles()
	}

	public func fetchUnreadArticlesAsync() async -> ArticleSetResult {
		guard let account = account else {
			assertionFailure("Expected feed.account, but got nil.")
			return .success(Set<Article>())
		}
		switch await account.fetchArticlesAsync(.webFeed(self)) {
		case .success(let articles):
			return .success(articles.unreadArticles())
		case .failure(let error):
			return .failure(error)
		}
	}
}

extension Folder: ArticleFetcher {
	
	public func fetchArticles() throws -> Set<Article> {
		guard let account = account else {
			assertionFailure("Expected folder.account, but got nil.")
			return Set<Article>()
		}
		return try account.fetchArticles(.folder(self, false))
	}

	public func fetchArticlesAsync() async -> ArticleSetResult {
		guard let account = account else {
			assertionFailure("Expected folder.account, but got nil.")
			return .success(Set<Article>())
		}
		return await account.fetchArticlesAsync(.folder(self, false))
	}

	public func fetchUnreadArticles() throws -> Set<Article> {
		guard let account = account else {
			assertionFailure("Expected folder.account, but got nil.")
			return Set<Article>()
		}
		return try account.fetchArticles(.folder(self, true))
	}

	public func fetchUnreadArticlesAsync() async -> ArticleSetResult {
		guard let account = account else {
			assertionFailure("Expected folder.account, but got nil.")
			return .success(Set<Article>())
		}
		return await account.fetchArticlesAsync(.folder(self, true))
	}
}
