/*
* SwiftLocation
* Easy and Efficent Location Tracker for Swift
*
* Created by:	Daniele Margutti
* Email:		hello@danielemargutti.com
* Web:			http://www.danielemargutti.com
* Twitter:		@danielemargutti
*
* Copyright © 2017 Daniele Margutti
*
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
* THE SOFTWARE.
*
*/

import Foundation
import CoreLocation
import MapKit

/// Shortcut to locator manager
public let Locator: LocatorManager = LocatorManager.shared

/// The main class responsibile of location services
public class LocatorManager: NSObject, CLLocationManagerDelegate {
	
	// MARK: PROPERTIES

	public class APIs {
		
		/// Google API key
		public var googleAPIKey: String?
		
	}
	
	/// Api key for helper services
	public private(set) var api = APIs()
	
	/// Shared instance of the location manager
	internal static let shared = LocatorManager()
	
	/// Core location internal manager
	internal var manager: CLLocationManager = CLLocationManager()
	
	/// Current queued location requests
	private var locationRequests: [LocationRequest] = []
	
	/// Current queued heading requests
	private var headingRequests: [HeadingRequest] = []

	/// `true` if service is currently updating current location
	public private(set) var isUpdatingLocation: Bool = false
	
	/// `true` if service is currently updating current heading
	public private(set) var isUpdatingHeading: Bool = false
	
	/// `true` if service is currenlty monitoring significant location changes
	public private(set) var isMonitoringSignificantLocationChanges = false
	
	/// It is possible to force enable background location fetch even if your set any kind of Authorizations
	public var backgroundLocationUpdates: Bool {
		set { self.manager.allowsBackgroundLocationUpdates = true }
		get { return self.manager.allowsBackgroundLocationUpdates }
	}
	
	/// Returns the most recent current location, or nil if the current
	/// location is unknown, invalid, or stale.
	private var _currentLocation: CLLocation? = nil
	public var currentLocation: CLLocation? {
		guard let l = self._currentLocation else {
			return nil
		}
		// invalid coordinates, discard id
		if (!CLLocationCoordinate2DIsValid(l.coordinate)) ||
			(l.coordinate.latitude == 0.0 || l.coordinate.longitude == 0.0) {
			return nil
		}
		return l
	}
	
	/// Last measured heading value
	public private(set) var currentHeading: CLHeading? = nil
	
	/// Last occurred error
	public private(set) var updateFailed: Bool = false
	
	/// Returns the current state of location services for this app,
	/// based on the system settings and user authorization status.
	public var state: ServiceState {
		return self.manager.serviceState
	}
	
	/// Return the current accuracy level of the location manager
	/// This value is managed automatically based upon current queued requests
	/// in order to better manage power consumption.
	public private(set) var accuracy: Accuracy {
		get { return Accuracy(self.manager.desiredAccuracy) }
		set {
			if self.manager.desiredAccuracy != newValue.threshold {
				self.manager.desiredAccuracy = newValue.threshold
			}
		}
	}
	
	private override init() {
		super.init()
		self.manager.delegate = self
		
		// iOS 9 requires setting allowsBackgroundLocationUpdates to true in order to receive
		// background location updates.
		// We only set it to true if the location background mode is enabled for this app,
		// as the documentation suggests it is a fatal programmer error otherwise.
		if #available(iOSApplicationExtension 9.0, *) {
			if CLLocationManager.hasBackgroundCapabilities {
				self.manager.allowsBackgroundLocationUpdates = true
			}
		}
	}
	
	// MARK: CURRENT LOCATION FUNCTIONS

	/// Asynchronously requests the current location of the device using location services,
	/// optionally waiting until the user grants the app permission
	/// to access location services before starting the timeout countdown.
	///
	/// - Parameters:
	///   - accuracy: The accuracy level desired (refers to the accuracy and recency of the location).
	///   - timeout: the amount of time to wait for a location with the desired accuracy before completing.
	/// - Returns: request
	@discardableResult
	public func currentPosition(accuracy: Accuracy, timeout: Timeout? = nil) -> LocationRequest {
		assert(Thread.isMainThread, "Locator functions should be called from main thread")
		let request = LocationRequest(mode: .oneshot, accuracy: accuracy.validateForGPSRequest, timeout: timeout)
		// Start timer if needs to be started (not delayed and valid timer)
		request.timeout?.startTimeout(force: false)
		// Append to the queue
		self.addLocation(request)
		return request
	}
	
	/// Creates a subscription for location updates that will execute the block once per update
	/// indefinitely (until canceled), regardless of the accuracy of each location.
	/// This method instructs location services to use the highest accuracy available
	/// (which also requires the most power).
	/// If an error occurs, the block will execute with a status other than INTULocationStatusSuccess,
	/// and the subscription will be canceled automatically.
	///
	/// - Parameters:
	///   - accuracy: The accuracy level desired (refers to the accuracy and recency of the location).
	/// - Returns: request
	@discardableResult
	public func subscribePosition(accuracy: Accuracy) -> LocationRequest {
		assert(Thread.isMainThread, "Locator functions should be called from main thread")
		let request = LocationRequest(mode: .continous, accuracy: accuracy.validateForGPSRequest, timeout: nil)
		// Append to the queue
		self.addLocation(request)
		return request
	}
	
	/// Creates a subscription for significant location changes that will execute the
	/// block once per change indefinitely (until canceled).
	/// If an error occurs, the block will execute with a status other than INTULocationStatusSuccess,
	/// and the subscription will be canceled automatically.
	///
	/// - Returns: request
	@discardableResult
	public func subscribeSignificantLocations() -> LocationRequest {
		assert(Thread.isMainThread, "Locator functions should be called from main thread")
		let request = LocationRequest(mode: .significant, accuracy: .any, timeout: nil)
		// Append to the queue
		self.addLocation(request)
		return request
	}
	
	// MARK: REVERSE GEOCODING
	
	/// Get the location from address string and return a `CLLocation` object.
	/// Request is started automatically.
	///
	/// - Parameters:
	///   - address: address string or place to search
	///   - region: A geographical region to use as a hint when looking up the specified address. Specifying a region lets you prioritize
	/// 			the returned set of results to locations that are close to some specific geographical area, which is typically
	///				the user’s current location. It's valid only if you are using apple services.
	///   - service: service to use, `nil` to user apple's built in service
	///   - timeout: timeout interval, if `nil` 10 seconds timeout is used
	///   - onSuccess: callback called on success
	///   - onFail: callback called on failure
	/// - Returns: request
	@discardableResult
	public func location(fromAddress address: String, in region: CLRegion? = nil,
	                     using service: GeocoderService? = nil, timeout: TimeInterval? = nil,
	                     onSuccess: @escaping GeocoderRequest_Success, onFail: @escaping GeocoderRequest_Failure) -> GeocoderRequest {
		var request = (service ?? .apple).newRequest(operation: .getLocation(address: address, region: region), timeout: timeout)
		request.success = onSuccess
		request.failure = onFail
		request.execute()
		return request
	}

	/// Get the location data from given coordinates.
	/// Request is started automatically.
	///
	/// - Parameters:
	///   - coordinates: coordinates to search
	///   - locale: The locale to use when returning the address information. You might specify a value for this parameter when you want the address returned in a locale that differs from the user's current language settings. Specify nil to use the user's default locale information. It's valid only if you are using apple services.
	///   - service: service to use, `nil` to user apple's built in service
	///   - onSuccess: callback called on success
	///   - onFail: callback called on failure
	///   - timeout: timeout interval, if `nil` 10 seconds timeout is used
	///   - timeout: timeout interval, if `nil` 10 seconds timeout is used
	@discardableResult
	public func location(fromCoordinates coordinates: CLLocationCoordinate2D, locale: Locale? = nil,
	                     using service: GeocoderService? = nil, timeout: TimeInterval? = nil,
	                     onSuccess: @escaping GeocoderRequest_Success, onFail: @escaping GeocoderRequest_Failure) -> GeocoderRequest {
		var request = (service ?? .apple).newRequest(operation: .getPlace(coordinates: coordinates, locale: locale), timeout: timeout)
		request.success = onSuccess
		request.failure = onFail
		request.execute()
		return request
	}

	
	// MARK: DEVICE HEADING FUNCTIONS

	/// Asynchronously requests the current heading of the device using location services.
	/// The current heading (the most recent one acquired, regardless of accuracy level),
	/// or nil if no valid heading was acquired
	///
	/// - Parameters:
	///   - accuracy: minimum accuracy you want to receive
	///   - minInterval: minimum interval between each request
	/// - Returns: request
	public func subscribeHeadingUpdates(accuracy: HeadingRequest.AccuracyDegree, minInterval: TimeInterval? = nil) -> HeadingRequest {
		// Create request
		let request = HeadingRequest(accuracy: accuracy, minInterval: minInterval)
		// Append it
		self.addHeadingRequest(request)
		return request
	}
	
	/// Stop running request
	///
	/// - Parameter request: request to stop
	@discardableResult
	public func stopRequest(_ request: Request) -> Bool {
		if let r = request as? LocationRequest {
			return self.stopLocationRequest(r)
		}
		if let r = request as? HeadingRequest {
			return self.stopHeadingRequest(r)
		}
		return false
	}
	
	/// HEADING HELPER FUNCTIONS

	/// Add heading request to queue
	///
	/// - Parameter request: request
	private func addHeadingRequest(_ request: HeadingRequest) {
		let state = self.manager.headingState
		guard state == .available else {
			DispatchQueue.main.async {
				request.failure?(state)
			}
			return
		}
		
		self.headingRequests.append(request)
		self.startUpdatingHeadingIfNeeded()
	}
	
	/// Start updating heading service if needed
	private func startUpdatingHeadingIfNeeded() {
		guard self.headingRequests.count > 0 else { return }
		self.manager.startUpdatingHeading()
		self.isUpdatingHeading = true
	}
	
	/// Stop heading services if possible
	private func stopUpdatingHeadingIfPossible() {
		if self.headingRequests.count == 0 {
			self.manager.stopUpdatingHeading()
			self.isUpdatingHeading = false
		}
	}
	
	
	/// Remove heading request
	///
	/// - Parameter request: request to remove
	/// - Returns: `true` if removed
	@discardableResult
	private func stopHeadingRequest(_ request: HeadingRequest) -> Bool {
		guard let idx = self.headingRequests.index(of: request) else { return false }
		self.headingRequests.remove(at: idx)
		self.stopUpdatingHeadingIfPossible()
		return true
	}
	
	// MARK: LOCATION HELPER FUNCTIONS
	
	/// Stop location request
	///
	/// - Parameter request: request
	/// - Returns: `true` if request is removed
	@discardableResult
	private func stopLocationRequest(_ request: LocationRequest?) -> Bool {
		guard let r = request, let idx = self.locationRequests.index(of: r) else { return false }
		
		if r.isRecurring { // Recurring requests can only be canceled
			r.timeout?.abort()
			self.locationRequests.remove(at: idx)
		} else {
			r.timeout?.forceTimeout() // force timeout
			self.completeLocationRequest(r) // complete request
		}
		return true
	}
	
	/// Adds the given location request to the array of requests, updates
	/// the maximum desired accuracy, and starts location updates if needed.
	///
	/// - Parameter request: request to add
	private func addLocation(_ request: LocationRequest) {
		/// No need to add this location request, because location services are turned off device-wide,
		/// or the user has denied this app permissions to use them.
		guard self.manager.servicesAreAvailable else {
			self.completeLocationRequest(request)
			return
		}
		
		switch request.mode {
		case .oneshot, .continous:
			// Determine the maximum desired accuracy for all existing location requests including the new one
			let maxAccuracy = self.maximumAccuracyInQueue(andRequest: request)
			self.accuracy = maxAccuracy
			
			self.startUpdatingLocationIfNeeded()
		case .significant:
			self.startMonitoringSignificantLocationChangesIfNeeded()
		}
		
		// Add to the queue
		self.locationRequests.append(request)
		// Process all location requests now, as we may be able to immediately
		// complete the request just added above
		// If a location update was recently received (stored in self.currentLocation)
		// that satisfies its criteria.
	}
	
	/// Return the max accuracy between the current queued requests and another request
	///
	/// - Parameter request: request, `nil` to compare only queued requests
	/// - Returns: max accuracy detail
	private func maximumAccuracyInQueue(andRequest request: LocationRequest? = nil) -> Accuracy {
		let maxAccuracy: Accuracy = self.locationRequests.map { $0.accuracy }.reduce(request?.accuracy ?? .any) { max($0,$1) }
		return maxAccuracy
	}
	
	internal func locationRequestDidTimedOut(_ request: LocationRequest) {
		if let _ = self.locationRequests.index(of: request) {
			self.completeLocationRequest(request)
		}
	}
	
	internal func startUpdatingLocationIfNeeded() {
		// Request authorization if not set yet
		self.requestAuthorizationIfNeeded()
		
		let requests = self.activeLocationRequest(excludingMode: .significant)
		if requests.count == 0 {
			self.manager.startUpdatingLocation()
			self.isUpdatingLocation = true
		}
	}
	
	/// Inform CLLocationManager to start monitoring significant location changes.
	internal func startMonitoringSignificantLocationChangesIfNeeded() {
		// request authorization if needed
		self.requestAuthorizationIfNeeded()
		
		let requests = self.activeLocationRequest(forMode: .significant)
		if requests.count == 0 {
			self.manager.startMonitoringSignificantLocationChanges()
			self.isMonitoringSignificantLocationChanges = true
		}
		
	}
	
	/// Return active requests excluding the one with given mode
	///
	/// - Parameter mode: mode
	/// - Returns: filtered list
	private func activeLocationRequest(excludingMode mode: LocationRequest.Mode) -> [LocationRequest] {
		return self.locationRequests.filter { $0.mode != mode }
	}
	
	/// Return active request of the given type
	///
	/// - Parameter mode: type to get
	/// - Returns: filtered list
	private func activeLocationRequest(forMode mode: LocationRequest.Mode) -> [LocationRequest] {
		return self.locationRequests.filter { $0.mode == mode }
	}

	/// As of iOS 8, apps must explicitly request location services permissions.
	/// SwiftLocation supports both levels, "Always" and "When In Use".
	/// If not called directly this function is called when the first enqueued request is added to the list.
	/// In this case SwiftLocation determines which level of permissions to request based on which description
	/// key is present in your app's Info.plist (If you provide values for both description keys,
	/// the more permissive "Always" level is requested.).
	/// If you need to set the authorization manually be sure to call this function before adding any request.
	///
	/// - Parameter type: authorization level, `nil` to use internal deterministic algorithm
	public func requestAuthorizationIfNeeded(_ type: AuthorizationLevel? = nil) {
		let currentAuthLevel = CLLocationManager.authorizationStatus()
		guard currentAuthLevel == .notDetermined else { return } // already authorized
		
		// Level to set is the one passed as argument or, if value is `nil`
		// is determined by reading values in host application's Info.plist
		let levelToSet = type ?? CLLocationManager.authorizationLevelFromInfoPlist
		self.manager.requestAuthorization(level: levelToSet)
	}
	
	// Iterates over the array of active location requests to check and see
	// if the most recent current location successfully satisfies any of their criteria so we
	// can return it without waiting for a new fresh value.
	private func processLocationRequests() {
		let location = self.currentLocation
		self.locationRequests.forEach {
			if $0.timeout?.hasTimedout ?? false {
				// Non-recurring request has timed out, complete it
				$0.location = location
				self.completeLocationRequest($0)
			} else {
				if let mostRecent = location {
					if $0.isRecurring {
						// This is a subscription request, which lives indefinitely
						// (unless manually canceled) and receives every location update we get.
						$0.location = location
						self.processRecurringRequest($0)
					} else {
						// This is a regular one-time location request
						if $0.hasValidThrehsold(forLocation: mostRecent) {
							// The request's desired accuracy has been reached, complete it
							$0.location = location
							self.completeLocationRequest($0)
						}
					}
				}
			}
		}
	}
	
	/// Immediately completes all active location requests.
	/// Used in cases such as when the location services authorization
	/// status changes to `.denied` or `.restricted`.
	private func completeAllLocationRequests() {
		let activeRequests = self.locationRequests
		activeRequests.forEach {
			self.completeLocationRequest($0)
		}
	}
	
	/// Complete passed location request and remove from queue if possible.
	///
	/// - Parameter request: request
	private func completeLocationRequest(_ request: LocationRequest?) {
		guard let r = request else { return }
		
		r.timeout?.abort() // stop any running timer
		self.removeLocationRequest(r) // remove from queue
		
		// SwiftLocation is not thread safe and should only be called from the main thread,
		// so we should already be executing on the main thread now.
		// DispatchQueue.main.async() is used to ensure that the completion block for a request
		// is not executed before the request ID is returned, for example in the
		// case where the user has denied permission to access location services and the request
		// is immediately completed with the appropriate error.
		DispatchQueue.main.async {
			if let error = r.error { // failed for some sort of error
				r.failure?(error,r.location)
			} else { // succeded
				r.success?(r.location!)
			}
		}
	}
	
	/// Handles calling a recurring location request's block with the current location.
	///
	/// - Parameter request: request
	private func processRecurringRequest(_ request: LocationRequest?) {
		guard let r = request, r.isRecurring else { return } // should be called by valid recurring request
		
		DispatchQueue.main.async {
			if let error = r.error {
				r.failure?(error,r.location)
			} else {
				r.success?(r.location!)
			}
		}
	}
	
	/// Removes a given location request from the array of requests,
	/// updates the maximum desired accuracy, and stops location updates if needed.
	///
	/// - Parameter request: request to remove
	private func removeLocationRequest(_ request: LocationRequest?) {
		guard let r = request else { return }
		guard let idx = self.locationRequests.index(of: r) else { return }
		self.locationRequests.remove(at: idx)
		
		switch r.mode {
		case .oneshot, .continous:
			// Determine the maximum desired accuracy for all remaining location requests
			let maxAccuracy = self.maximumAccuracyInQueue()
			self.accuracy = maxAccuracy
			// Stop if no other location requests are running
			self.stopUpdatingLocationIfPossible()
		case .significant:
			self.stopMonitoringSignificantLocationChangesIfPossible()
		}
	}
	
	/// Checks to see if there are any outstanding locationRequests,
	/// and if there are none, informs CLLocationManager to stop sending
	/// location updates. This is done as soon as location updates are no longer
	/// needed in order to conserve the device's battery.
	private func stopUpdatingLocationIfPossible() {
		let requests = self.activeLocationRequest(excludingMode: .significant)
		if requests.count == 0 { // can be stopped
			self.manager.stopUpdatingLocation()
			self.isUpdatingLocation = false
		}
	}
	
	/// Checks to see if there are any outsanding significant location request in queue.
	/// If not we can stop monitoring for significant location changes and conserve device's battery.
	private func stopMonitoringSignificantLocationChangesIfPossible() {
		let requests = self.activeLocationRequest(forMode: .significant)
		if requests.count == 0 { // stop
			self.manager.stopMonitoringSignificantLocationChanges()
			self.isMonitoringSignificantLocationChanges = false
		}
	}
	
	// MARK: CLLocationManager Delegates
	
	public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
	 	// Clear any previous errors
		self.updateFailed = false
		
		// Store last data
		let recentLocations = locations.min(by: { (a, b) -> Bool in
			return a.timestamp.timeIntervalSinceNow < b.timestamp.timeIntervalSinceNow
		})
		self._currentLocation = recentLocations
		
		// Process the location requests using the updated location
		self.processLocationRequests()
	}
	
	public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		self.updateFailed = true // an error has occurred
		
		self.locationRequests.forEach {
			if $0.isRecurring { // Keep the recurring request alive
				self.processRecurringRequest($0)
			} else { // Fail any non-recurring requests
				self.completeLocationRequest($0)
			}
		}
	}
	
	public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
		guard status != .denied && status != .restricted else {
			// Clear out any active location requests (which will execute the blocks
			// with a status that reflects
			// the unavailability of location services) since we now no longer have
			// location services permissions
			self.completeAllLocationRequests()
			return
		}
		
		if status == .authorizedAlways || status == .authorizedWhenInUse {
			self.locationRequests.forEach({
				// Start the timeout timer for location requests that were waiting for authorization
				$0.timeout?.startTimeout()
			})
		}
	}
	
	public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
		self.currentHeading = newHeading
		self.processRecurringHeadingRequests()
	}
	
	private func processRecurringHeadingRequests() {
		let h = self.currentHeading
		DispatchQueue.main.async {
			self.headingRequests.forEach { r in
				if let err = r.error {
					r.failure?(err)
					self.stopHeadingRequest(r)
				} else {
					if r.isValidHeadingForRequest(h) {
						r.heading = h
						r.success?(r.heading!)
					}
				}
			}
		}
	}
}
