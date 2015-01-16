import LlamaKit

/// A SignalProducer creates Signals that can produce values of type T.
///
/// SignalProducers can be used to represent operations or tasks, like network
/// requests, where each invocation of start() will create a new underlying
/// operation. This ensures that consumers will receive the results, versus a
/// plain Signal, where the results might be sent before any observers are
/// attached.
///
/// Because of the behavior of start(), different Signals created from the
/// producer may see a different version of Events. The Events may arrive in a
/// different order between Signals, or the stream might be completely
/// different!
public struct SignalProducer<T> {
	private let startHandler: (Signal<T>.Observer, CompositeDisposable) -> ()

	/// Initializes a SignalProducer that will invoke the given closure once
	/// for each invocation of start().
	///
	/// The events that the closure puts into the given sink will become the
	/// events sent by the started Signal to its observers.
	///
	/// If the Disposable returned from start() is disposed, the given
	/// CompositeDisposable will be disposed as well, at which point work should
	/// be cancelled, and any temporary resources cleaned up. The
	/// CompositeDisposable will also be disposed when an `Error` or `Completed`
	/// event is sent to the sink.
	public init(_ startHandler: (Signal<T>.Observer, CompositeDisposable) -> ()) {
		self.startHandler = startHandler
	}

	/// Creates a producer for a Signal that will immediately send one value
	/// then complete.
	public init(value: T) {
		self.init({ observer, disposable in
			sendNext(observer, value)
			sendCompleted(observer)
		})
	}

	/// Creates a producer for a Signal that will immediately send an error.
	public init(error: NSError) {
		self.init({ observer, disposable in
			sendError(observer, error)
		})
	}

	/// Creates a producer for a Signal that will immediately send one value
	/// then complete, or immediately send an error, depending on the given
	/// Result.
	public init(result: Result<T>) {
		switch result {
		case let .Success(value):
			self.init(value: value.unbox)

		case let .Failure(error):
			self.init(error: error)
		}
	}

	/// Creates a producer for a Signal that will immediately send the values
	/// from the given sequence, then complete.
	public init<S: SequenceType where S.Generator.Element == T>(values: S) {
		self.init({ observer, disposable in
			var generator = values.generate()

			while !disposable.disposed {
				if let value: T = generator.next() {
					sendNext(observer, value)
				} else {
					break
				}
			}

			sendCompleted(observer)
		})
	}

	/// A producer for a Signal that will immediately complete without sending
	/// any values.
	public static var empty: SignalProducer {
		return self { observer, disposable in
			sendCompleted(observer)
		}
	}

	/// A producer for a Signal that will never send any events.
	public static var never: SignalProducer {
		return self { _ in () }
	}

	/// Creates a buffer for Events, with the given capacity, and a
	/// SignalProducer for a signal that will send Events from the buffer.
	///
	/// When events are put into the returned observer (sink), they will be
	/// added to the buffer. If the buffer is already at capacity, the earliest
	/// (oldest) event will be dropped to make room for the new event.
	///
	/// Signals created from the returned producer will stay alive until an
	/// `Error` or `Completed` is added to the buffer. If the buffer does not
	/// contain such an event when the Signal is started, all events sent to the
	/// returned observer will be automatically forwarded to the Signal’s
	/// observers until a terminating event is received.
	///
	/// After an `Error` or `Completed` event has been added to the buffer, the
	/// observer will not add any further events.
	public static func buffer(_ capacity: Int = Int.max) -> (SignalProducer, Signal<T>.Observer) {
		precondition(capacity >= 0)

		let lock = NSRecursiveLock()
		lock.name = "org.reactivecocoa.ReactiveCocoa.SignalProducer.buffer"

		var events: [Event<T>] = []
		var observers: Bag<Signal<T>.Observer>? = Bag()

		let producer = self { observer, disposable in
			if disposable.disposed {
				return
			}

			lock.lock()
			for event in events {
				observer.put(event)
			}

			let token = observers?.insert(observer)
			lock.unlock()

			if let token = token {
				disposable.addDisposable {
					lock.lock()
					observers?.removeValueForToken(token)
					lock.unlock()
				}
			}
		}

		let observer = Signal<T>.Observer { event in
			lock.lock()

			// If not disposed…
			if let liveObservers = observers {
				if event.isTerminating {
					observers = nil
				}

				events.append(event)
				while events.count > capacity {
					events.removeAtIndex(0)
				}

				for observer in liveObservers {
					observer.put(event)
				}
			}

			lock.unlock()
		}

		return (producer, observer)
	}

	/// Creates a SignalProducer that will attempt the given operation once for
	/// each invocation of start().
	///
	/// Upon success, the started signal will send the resulting value then
	/// complete. Upon failure, the started signal will send the error that
	/// occurred.
	public static func try(operation: () -> Result<T>) -> SignalProducer {
		return self { observer, disposable in
			if disposable.disposed {
				return
			}

			switch operation() {
			case let .Success(value):
				sendNext(observer, value.unbox)
				sendCompleted(observer)

			case let .Failure(error):
				sendError(observer, error)
			}
		}
	}

	/// Creates a SignalProducer that will attempt the given operation once for
	/// each invocation of start().
	///
	/// If the returned value is not nil, the signal will send that value then
	/// complete. If nil is returned, the signal will send the error that was
	/// returned by reference, or RACError.Empty otherwise.
	public static func try(operation: NSErrorPointer -> T?) -> SignalProducer {
		return try {
			var error: NSError?
			if let value = operation(&error) {
				return success(value)
			} else {
				return failure(error ?? RACError.Empty.error)
			}
		}
	}

	/// Creates a Signal from the producer, passes it into the given closure,
	/// then starts sending events on the Signal when the closure has returned.
	///
	/// The closure will also receive a disposable which can be used to cancel
	/// the work associated with the signal, and prevent any future events from
	/// being sent. Add other disposables to the CompositeDisposable to perform
	/// additional cleanup upon termination or cancellation.
	///
	/// Returns a Disposable which can be used to cancel the work associated
	/// with the Signal, and prevent any future events from being sent.
	public func start(setUp: (Signal<T>, CompositeDisposable) -> ()) -> Disposable {
		var observer: Signal<T>.Observer!
		var disposable: CompositeDisposable!

		let signal = Signal<T> { innerObserver, innerDisposable in
			observer = innerObserver
			disposable = innerDisposable
		}

		setUp(signal, disposable)

		if !disposable.disposed {
			startHandler(observer, disposable)
		}

		return disposable
	}

	/// Creates a Signal from the producer, then attaches the given sink to the
	/// Signal as an observer.
	///
	/// Returns a Disposable which can be used to cancel the work associated
	/// with the Signal, and prevent any future events from being put into the
	/// sink.
	public func start<S: SinkType where S.Element == Event<T>>(sink: S) -> Disposable {
		return start { signal, disposable in
			signal.observe(sink)
			return
		}
	}

	/// Creates a Signal from the producer, then adds exactly one observer to
	/// the Signal, which will invoke the given callbacks when events are
	/// received.
	///
	/// Returns a Disposable which can be used to cancel the work associated
	/// with the Signal, and prevent any future callbacks from being invoked.
	public func start(next: T -> () = doNothing, error: NSError -> () = doNothing, completed: () -> () = doNothing) -> Disposable {
		return start { signal, disposable in
			signal.observe(next: next, error: error, completed: completed)
			return
		}
	}

	/// Lifts a Signal operator to operate upon SignalProducers instead.
	///
	/// In other words, this will create a new SignalProducer which will apply
	/// the given Signal operator to _every_ created Signal, just as if the
	/// operator had been applied to each Signal yielded from start().
	public func lift<U>(transform: Signal<T> -> Signal<U>) -> SignalProducer<U> {
		return SignalProducer<U> { observer, outerDisposable in
			self.start { signal, innerDisposable in
				outerDisposable.addDisposable(innerDisposable)

				transform(signal).observe(observer)
				return
			}

			return
		}
	}
}

/// Applies a Signal operator to a SignalProducer (equivalent to
/// SignalProducer.lift).
///
/// This will create a new SignalProducer which will apply the given Signal
/// operator to _every_ created Signal, just as if the operator had been applied
/// to each Signal yielded from start().
///
/// Example:
///
/// 	let filteredProducer = intProducer |> filter { num in num % 2 == 0 }
public func |> <T, U>(producer: SignalProducer<T>, transform: Signal<T> -> Signal<U>) -> SignalProducer<U> {
	return producer.lift(transform)
}

/// Applies a SignalProducer operator to a SignalProducer.
///
/// Example:
///
/// 	filteredProducer
/// 	|> startOn(MainScheduler())
/// 	|> start { signal in
/// 		signal.observe(next: { num in println(num) })
/// 	}
public func |> <T, U>(producer: SignalProducer<T>, transform: SignalProducer<T> -> U) -> U {
	return transform(producer)
}

/// Creates a repeating timer of the given interval, with a reasonable
/// default leeway, sending updates on the given scheduler.
///
/// This timer will never complete naturally, so all invocations of start() must
/// be disposed to avoid leaks.
public func timer(interval: NSTimeInterval, onScheduler scheduler: DateScheduler) -> SignalProducer<NSDate> {
	// Apple's "Power Efficiency Guide for Mac Apps" recommends a leeway of
	// at least 10% of the timer interval.
	return timer(interval, onScheduler: scheduler, withLeeway: interval * 0.1)
}

/// Creates a repeating timer of the given interval, sending updates on the
/// given scheduler.
///
/// This timer will never complete naturally, so all invocations of start() must
/// be disposed to avoid leaks.
public func timer(interval: NSTimeInterval, onScheduler scheduler: DateScheduler, withLeeway leeway: NSTimeInterval) -> SignalProducer<NSDate> {
	precondition(interval >= 0)
	precondition(leeway >= 0)

	return SignalProducer { observer, compositeDisposable in
		if compositeDisposable.disposed {
			return
		}

		let disposable = scheduler.scheduleAfter(scheduler.currentDate.dateByAddingTimeInterval(interval), repeatingEvery: interval, withLeeway: leeway) {
			sendNext(observer, scheduler.currentDate)
		}

		compositeDisposable.addDisposable(disposable)
	}
}

/// Injects side effects to be performed upon the specified signal events.
public func on<T>(started: () -> () = doNothing, event: Event<T> -> () = doNothing, next: T -> () = doNothing, error: NSError -> () = doNothing, completed: () -> () = doNothing, terminated: () -> () = doNothing, disposed: () -> () = doNothing)(producer: SignalProducer<T>) -> SignalProducer<T> {
	return SignalProducer { observer, compositeDisposable in
		started()
		compositeDisposable.addDisposable(disposed)

		producer.start { signal, disposable in
			compositeDisposable.addDisposable(disposable)

			let innerObserver = Signal<T>.Observer { receivedEvent in
				event(receivedEvent)

				switch receivedEvent {
				case let .Next(value):
					next(value.unbox)

				case let .Error(err):
					error(err)

				case let .Completed:
					completed()
				}

				if receivedEvent.isTerminating {
					terminated()
				}

				observer.put(receivedEvent)
			}

			signal.observe(innerObserver)
		}
	}
}

/*
public func concat<T>(producer: SignalProducer<SignalProducer<T>>) -> SignalProducer<T>
public func concatMap<T, U>(transform: T -> SignalProducer<U>)(producer: SignalProducer<T>) -> SignalProducer<U>
public func merge<T>(producer: SignalProducer<SignalProducer<T>>) -> SignalProducer<T>
public func mergeMap<T, U>(transform: T -> SignalProducer<U>)(producer: SignalProducer<T>) -> SignalProducer<U>
public func switchMap<T, U>(transform: T -> SignalProducer<U>)(producer: SignalProducer<T>) -> SignalProducer<U>
public func switchToLatest<T>(producer: SignalProducer<SignalProducer<T>>) -> SignalProducer<T>

public func catch<T>(handler: NSError -> SignalProducer<T>)(producer: SignalProducer<T>) -> SignalProducer<T>
public func combineLatestWith<T, U>(otherSignalProducer: SignalProducer<U>)(producer: SignalProducer<T>) -> SignalProducer<(T, U)>
public func concat<T>(next: SignalProducer<T>)(producer: SignalProducer<T>) -> SignalProducer<T>
public func repeat<T>(count: Int)(producer: SignalProducer<T>) -> SignalProducer<T>
public func retry<T>(count: Int)(producer: SignalProducer<T>) -> SignalProducer<T>
public func startOn<T>(scheduler: Scheduler)(producer: SignalProducer<T>) -> SignalProducer<T>
public func takeUntil<T>(trigger: SignalProducer<()>)(producer: SignalProducer<T>) -> SignalProducer<T>
public func takeUntilReplacement<T>(replacement: SignalProducer<T>)(producer: SignalProducer<T>) -> SignalProducer<T>
public func then<T, U>(replacement: SignalProducer<U>)(producer: SignalProducer<T>) -> SignalProducer<U>
public func zipWith<T, U>(otherSignalProducer: SignalProducer<U>)(producer: SignalProducer<T>) -> SignalProducer<(T, U)>
*/

/// Starts the producer, then blocks, waiting for the first value.
public func first<T>(producer: SignalProducer<T>) -> Result<T> {
	let semaphore = dispatch_semaphore_create(0)
	var result: Result<T> = failure(RACError.ExpectedCountMismatch.error)

	producer.start { signal, disposable in
		disposable.addDisposable {
			dispatch_semaphore_signal(semaphore)
			return
		}

		signal.observe(next: { value in
			result = success(value)
			disposable.dispose()
		}, error: { error in
			result = failure(error)
			disposable.dispose()
		}, completed: {
			disposable.dispose()
		})

		return
	}

	dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
	return result
}

/// SignalProducer.start() as a free function, for easier use with |>.
public func start<T>(setUp: (Signal<T>, CompositeDisposable) -> ())(producer: SignalProducer<T>) -> Disposable {
	return producer.start(setUp)
}

/// SignalProducer.start() as a free function, for easier use with |>.
public func start<T, S: SinkType where S.Element == Event<T>>(sink: S)(producer: SignalProducer<T>) -> Disposable {
	return producer.start(sink)
}

/// SignalProducer.start() as a free function, for easier use with |>.
public func start<T>(next: T -> () = doNothing, error: NSError -> () = doNothing, completed: () -> () = doNothing)(producer: SignalProducer<T>) -> Disposable {
	return producer.start(next: next, error: error, completed: completed)
}
