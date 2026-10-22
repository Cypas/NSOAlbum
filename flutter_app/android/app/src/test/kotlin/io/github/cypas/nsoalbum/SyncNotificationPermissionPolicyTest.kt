package io.github.cypas.nsoalbum

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class SyncNotificationPermissionPolicyTest {
    @Test
    fun syncCompletionWaitsForAnExistingUpdatePermissionRequest() {
        val fixture = PermissionFixture()
        assertTrue(fixture.delivery.beginExternalRequest(9216))
        fixture.delivery.syncCompleted("title", "added 2")

        assertEquals(0, fixture.requests)
        assertTrue(fixture.posted.isEmpty())
        fixture.granted = true
        fixture.delivery.complete(9216)

        assertEquals(listOf("title" to "added 2"), fixture.posted)
    }

    @Test
    fun syncPermissionRequestPreventsASecondUpdatePrompt() {
        val fixture = PermissionFixture()
        fixture.delivery.syncCompleted("title", "added 3")
        assertEquals(1, fixture.requests)
        assertFalse(fixture.delivery.beginExternalRequest(9216))
        fixture.granted = true
        fixture.delivery.complete(9217)
        assertEquals(listOf("title" to "added 3"), fixture.posted)
    }

    @Test
    fun onlyTheLatestSummaryIsRetainedWhilePermissionIsPending() {
        val fixture = PermissionFixture()
        fixture.delivery.syncCompleted("round one", "added 2")
        fixture.delivery.syncCompleted("round two", "added 4")
        fixture.granted = true
        fixture.delivery.complete(9217)
        fixture.delivery.complete(9217)

        assertEquals(1, fixture.requests)
        assertEquals(listOf("round two" to "added 4"), fixture.posted)
    }

    @Test
    fun denialDropsThePendingSummaryAndDoesNotPromptAgain() {
        val fixture = PermissionFixture()
        fixture.delivery.syncCompleted("first", "added 1")
        fixture.delivery.complete(9217)
        fixture.delivery.syncCompleted("second", "added 2")
        fixture.granted = true
        fixture.delivery.complete(9217)

        assertEquals(1, fixture.requests)
        assertTrue(fixture.posted.isEmpty())
        fixture.delivery.syncCompleted("third", "added 3")
        assertEquals(listOf("third" to "added 3"), fixture.posted)
    }

    @Test
    fun denyingTheUpdatePromptAlsoPreventsAutomaticSyncFromPromptingAgain() {
        val fixture = PermissionFixture()
        assertTrue(fixture.delivery.beginExternalRequest(9216))
        fixture.delivery.syncCompleted("first", "added 1")
        fixture.delivery.complete(9216)
        fixture.delivery.syncCompleted("second", "added 2")

        assertEquals(0, fixture.requests)
        assertTrue(fixture.posted.isEmpty())
    }

    @Test
    fun unrelatedPermissionCallbacksCannotPublishOrRetireTheActiveRequest() {
        val fixture = PermissionFixture()
        fixture.delivery.syncCompleted("title", "added 1")
        fixture.granted = true
        fixture.delivery.complete(9216)
        assertTrue(fixture.posted.isEmpty())
        assertFalse(fixture.delivery.beginExternalRequest(9216))
        fixture.delivery.complete(9217)
        assertEquals(listOf("title" to "added 1"), fixture.posted)
    }

    @Test
    fun retirementDiscardsPendingDeliveryAndIgnoresLateCallbacks() {
        val fixture = PermissionFixture()
        fixture.delivery.syncCompleted("title", "added 1")
        fixture.delivery.close()
        fixture.granted = true
        fixture.delivery.complete(9217)
        fixture.delivery.syncCompleted("late", "added 2")

        assertTrue(fixture.posted.isEmpty())
        assertFalse(fixture.delivery.beginExternalRequest(9216))
    }

    @Test
    fun aFailedPermissionLaunchDoesNotLeaveTheCoordinatorBusy() {
        val fixture = PermissionFixture(failRequest = true)
        try {
            fixture.delivery.syncCompleted("title", "added 1")
            fail("Expected a permission-launch failure")
        } catch (_: IllegalStateException) {
            // The caller maps the platform failure; the queue must not stay busy.
        }
        assertTrue(fixture.delivery.beginExternalRequest(9216))
        fixture.granted = true
        fixture.delivery.complete(9216)
        assertTrue(fixture.posted.isEmpty())
    }

    @Test
    fun requestsPermissionOnlyOnceWhenFirstSyncNotificationNeedsIt() {
        assertTrue(
            SyncNotificationPermissionPolicy.shouldRequest(
                sdkInt = 33,
                permissionGranted = false,
                alreadyRequested = false,
                anotherPermissionRequestInProgress = false,
            ),
        )
        assertFalse(
            SyncNotificationPermissionPolicy.shouldRequest(
                sdkInt = 33,
                permissionGranted = false,
                alreadyRequested = true,
                anotherPermissionRequestInProgress = false,
            ),
        )
        assertFalse(
            SyncNotificationPermissionPolicy.shouldRequest(
                sdkInt = 34,
                permissionGranted = true,
                alreadyRequested = false,
                anotherPermissionRequestInProgress = false,
            ),
        )
        assertFalse(
            SyncNotificationPermissionPolicy.shouldRequest(
                sdkInt = 32,
                permissionGranted = false,
                alreadyRequested = false,
                anotherPermissionRequestInProgress = false,
            ),
        )
        assertFalse(
            SyncNotificationPermissionPolicy.shouldRequest(
                sdkInt = 34,
                permissionGranted = false,
                alreadyRequested = false,
                anotherPermissionRequestInProgress = true,
            ),
        )
    }

    private class PermissionFixture(failRequest: Boolean = false) {
        var granted = false
        var requested = false
        var requests = 0
        val posted = mutableListOf<Pair<String, String>>()
        val delivery = SyncNotificationPermissionCoordinator(
            sdkInt = 33,
            permissionGranted = { granted },
            alreadyRequested = { requested },
            markRequested = { requested = true },
            requestPermission = {
                requests++
                if (failRequest) throw IllegalStateException("synthetic failure")
            },
            post = { title, body -> posted.add(title to body) },
        )
    }
}
