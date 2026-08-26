import Foundation

@MainActor
extension AuthState {
    // MARK: - Subscription

    func refreshSubscriptionIfNeeded() {
        guard isLoggedIn || accessToken != nil else { return }
        Task { await refreshSubscription() }
    }

    @discardableResult
    func refreshSubscription() async -> BillingSubscriptionSnapshot? {
        guard let token = accessToken else {
            subscription = .none
            return nil
        }

        isLoadingSubscription = true
        defer { isLoadingSubscription = false }

        do {
            let snapshot = try await fetchSubscription(token)
            applySubscriptionSnapshot(snapshot)
            return snapshot
        } catch let error as AuthError {
            subscriptionError = error.localizedDescription
            return nil
        } catch {
            subscriptionError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func syncSubscription() async throws -> BillingSubscriptionSnapshot {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        guard !isSyncingSubscription else { return subscription }

        isSyncingSubscription = true
        defer { isSyncingSubscription = false }

        let snapshot = try await syncBillingSubscription(token)
        applySubscriptionSnapshot(snapshot)
        return snapshot
    }

    @discardableResult
    func refreshUsage() async -> CloudUsageStats? {
        guard let token = accessToken else {
            usageStats = .empty
            usageCredits = nil
            return nil
        }

        isLoadingUsage = true
        defer { isLoadingUsage = false }

        do {
            let snapshot = try await fetchCurrentPeriodUsageStats(token)
            usageStats = snapshot.stats
            usageCredits = snapshot.credits
            usagePeriodStart = snapshot.periodStart
            usagePeriodEnd = snapshot.periodEnd
            usageError = nil
            return snapshot.stats
        } catch let error as AuthError {
            if error.authErrorCode == "USAGE_PERIOD_UNAVAILABLE" {
                usageStats = .empty
                usageCredits = nil
                usagePeriodStart = nil
                usagePeriodEnd = nil
                usageError = nil
            } else {
                usageError = error.localizedDescription
            }
            return nil
        } catch {
            usageError = error.localizedDescription
            return nil
        }
    }

    func startCheckout(planCode: String = BillingPlan.defaultPlanCode) async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let session = try await createCheckoutSession(token, planCode)
        if !subscription.hasPaidSubscription {
            pendingCheckoutSubscriptionEntitlement = true
        }
        startCheckoutPolling()
        return session.url
    }

    func createBillingPortalSession() async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let session = try await createPortalSession(token)
        return session.url
    }

    func requestBillingPageToken() async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let response = try await issueBillingPageToken(token)
        return response.plansURL
    }

    private func startCheckoutPolling() {
        checkoutPollingTask?.cancel()
        checkoutPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0 ..< Self.checkoutPollingAttempts {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.checkoutPollingInterval)
                }
                guard !Task.isCancelled else { return }
                _ = await refreshSubscription()
                if subscription.hasPaidSubscription {
                    return
                }
            }
            pendingCheckoutSubscriptionEntitlement = false
        }
    }

    private func applySubscriptionSnapshot(_ snapshot: BillingSubscriptionSnapshot) {
        let wasEntitled = subscription.entitled
        let hadPaidSubscription = subscription.hasPaidSubscription
        subscription = snapshot
        subscriptionError = nil
        let becameEntitled = !wasEntitled && snapshot.entitled
        let becamePaid = !hadPaidSubscription && snapshot.hasPaidSubscription
        if pendingCheckoutSubscriptionEntitlement, becameEntitled || becamePaid {
            pendingCheckoutSubscriptionEntitlement = false
            NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: self)
        }
    }
}
