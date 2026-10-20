import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Delegate transport bounds memory before appending bytes on Apple and Linux.
final class BoundedHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let mutex = NSLock()
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var response: HTTPURLResponse?
  private var bytes = Data()
  private let limit: Int
  private var cancelled = false
  init(limit: Int) { self.limit = limit }
  static func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
    let transport = BoundedHTTP(limit: limit)
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          transport.start(request, continuation: continuation)
        }
      }, onCancel: { transport.cancel() })
  }
  private func start(
    _ request: URLRequest, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
  ) {
    mutex.lock()
    if cancelled {
      mutex.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(with: request)
    self.task = task
    mutex.unlock()
    task.resume()
  }
  private func cancel() {
    mutex.lock()
    cancelled = true
    let task = self.task
    mutex.unlock()
    task?.cancel()
    finish(.failure(CancellationError()))
  }
  private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
    mutex.lock()
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    self.session = nil
    self.task = nil
    mutex.unlock()
    continuation?.resume(with: result)
    session?.invalidateAndCancel()
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(OtaFailure.invalidManifest))
      return
    }
    self.response = http
    if http.statusCode == 304 {
      completionHandler(.cancel)
      finish(.success((Data(), http)))
      return
    }
    if http.statusCode == 200 && response.expectedContentLength > limit {
      completionHandler(.cancel)
      finish(.failure(OtaFailure.integrity))
      return
    }
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let http = response else { return }
    let maximum = http.statusCode == 200 ? limit : 4096
    if data.count > maximum - bytes.count {
      if http.statusCode == 200 {
        finish(.failure(OtaFailure.integrity))
      } else {
        bytes.append(data.prefix(maximum - bytes.count))
        finish(.success((bytes, http)))
      }
    } else {
      bytes.append(data)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      finish(.failure(error))
    } else if let response = response {
      finish(.success((bytes, response)))
    } else {
      finish(.failure(OtaFailure.invalidManifest))
    }
  }
}
