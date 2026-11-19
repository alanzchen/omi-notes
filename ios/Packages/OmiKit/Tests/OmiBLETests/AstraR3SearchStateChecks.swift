// Astra's IT3 search-state checks (omi-notes-reviews/nightly-2026-11-19-it3/swift/AstraR3SearchStateChecks.swift),
// copied apart from nesting in RetryFlowTests (serialized: suites on the shared AppServerStub run one at a time). Red on
// 3d671f0 with her extraction (2 of 5); since R5 the adapter mirrors the R5 HomeView task/load bodies (they call
// AppModel.searchRerun) and two checks were added: an unchanged error stays put, and Retry asks again.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol
// Mechanically extracted task/load bodies from the pinned HomeView. This is a host state-execution
// adapter, not SwiftUI rendering or lifecycle evidence. Only @State storage/view inputs are substituted.
@MainActor final class ExtractedSearchState {
 let model: AppModel
 var query: String
 var personId: String?
 var range: AppModel.SearchRange = .any
 var result: AppModel.SearchResult?
 var error: String?
 var loading = false
 var generation = 0
 var inFlight = false
 var retries = 0
 var answeredFor: String?
 var answeredRevision: Int?
 init(_ model:AppModel, query:String="budget") {self.model=model;self.query=query}
 func reappear() async {
            let rerun = AppModel.searchRerun(answered: answeredFor, answeredRevision: answeredRevision, question: question,
                                             revision: model.notesRevision, hasResult: result != nil, hasError: error != nil)
            if rerun == .keep {
                SearchLog.line("kept", "the same search reappeared; its answer stays")
                return
            }
            generation += 1
            let mine = generation
            if rerun == .fresh { result = nil }  // a refresh keeps the results shown until its answer
            error = nil
            inFlight = true
            try? await Task.sleep(for: .milliseconds(300))  // wait for typing to pause
            guard !Task.isCancelled else {
                if mine == generation { inFlight = false }  // not replaced by a newer search: nothing runs now
                return
            }
            SearchLog.line("started", "search \(mine)")
            await load(more: false)
            if mine == generation { inFlight = false }
 }
 /// The production error branch's Retry button (R5).
 func retry() async { retries += 1; await reappear() }
    private var key: String { "\(query)|\(personId ?? "")|\(range.rawValue)" }
    private var question: String { "\(key)|\(model.serverIdentity)|\(retries)" }

    private func load(more: Bool) async {
        let asked = generation, question = self.question, revision = model.notesRevision
        loading = true
        defer { loading = false }
        let answer = await model.search(query, personId: personId, range: range, before: more ? result?.nextCursor : nil)
        guard asked == generation else { return }  // the search changed meanwhile: this answer is for another one
        switch answer {
        case .failure(is CancellationError):
            SearchLog.line("dropped", "search \(asked) ended without an answer")
            return
        case .success(let r):
            if more, var current = result {
                let ids = Set(current.conversations.map(\.id))
                current.conversations += r.conversations.filter { !ids.contains($0.id) }
                current.nextCursor = r.nextCursor
                result = current
            } else {
                result = r
            }
            error = nil
            answeredFor = question
            answeredRevision = revision
        case .failure(let e):
            result = nil  // never leave results that don't match the chosen search
            error = (e as? LocalizedError)?.errorDescription ?? "Couldn't search: \(AppModel.describe(e))"
            answeredFor = question
            answeredRevision = revision
        }
    }
}

extension RetryFlowTests {
@MainActor @Suite(.serialized) struct AstraR3SearchStateChecks {
 let path="/v1/conversations/search"
 @Test func sameUnchangedSearchKeepsItsSuccessfulAnswer() async throws {
  let(m,root)=try RetryFlowTests().model();defer{try? FileManager.default.removeItem(at:root)}
  await m.refreshServer();AppServerStub.routes[path]=[(200,#"{"conversations":[],"next_cursor":null}"#)]
  let v=ExtractedSearchState(m);await v.reappear();#expect(v.result != nil)
  let before=AppServerStub.requests.filter{$0.path==path}.count
  await v.reappear();#expect(AppServerStub.requests.filter{$0.path==path}.count==before)
  #expect(!v.inFlight && !v.loading)
 }
 @Test func aCompletedFailureMustBeRefreshableAfterServerRecovery() async throws {
  let(m,root)=try RetryFlowTests().model();defer{try? FileManager.default.removeItem(at:root)}
  await m.refreshServer();AppServerStub.routes[path]=[(503,#"{"error":"busy","detail":"synthetic transient outage"}"#)]
  let v=ExtractedSearchState(m);await v.reappear();try #require(v.error != nil)
  let identity=m.serverIdentity
  AppServerStub.routes[path]=[(200,#"{"conversations":[{"id":"recovered","status":"done"}],"next_cursor":null}"#)]
  await m.refreshServer();#expect(m.serverIdentity==identity)
  await v.reappear()
  #expect(v.error==nil && v.result?.conversations.first?.id=="recovered", "same-key error is permanently retained; production error branch has no Retry")
  // Prove the real model can now answer; this is not a fake server/fixture failure.
  #expect(try await m.search("budget",personId:nil,range:.any).get().conversations.first?.id=="recovered")
 }
 @Test func aNewlySavedNoteMustNotRemainAbsentOnReappearance() async throws {
  let(m,root)=try RetryFlowTests().model();defer{try? FileManager.default.removeItem(at:root)}
  await m.refreshServer();AppServerStub.offline=true
  let v=ExtractedSearchState(m);await v.reappear();try #require(v.result?.conversations.isEmpty==true)
  let detail=try JSONDecoder().decode(ConversationDetail.self,from:Data(NoteCacheTests().detailJSON.utf8))
  m.saveForOffline(detail,m.engine.settings.serverConfig())
  #expect(try await m.search("budget",personId:nil,range:.any).get().conversations.map(\.id)==["c1"])
  await v.reappear()
  #expect(v.result?.conversations.map(\.id)==["c1"],"kept answer ignores new saved-note data")
 }
 @Test func changedQueryAndServerIdentityGetNewAnswers() async throws {
  let(m,root)=try RetryFlowTests().model();defer{try? FileManager.default.removeItem(at:root)}
  await m.refreshServer();AppServerStub.routes[path]=[(200,#"{"conversations":[],"next_cursor":null}"#)]
  let v=ExtractedSearchState(m);await v.reappear()
  AppServerStub.routes[path]=[(200,#"{"conversations":[{"id":"changed","status":"done"}],"next_cursor":null}"#)]
  v.query="changed";await v.reappear();#expect(v.result?.conversations.first?.id=="changed")
  try m.engine.settings.setServer(url:URL(string:"https://second.invalid")!,token:"synthetic")
  await m.refreshServer();AppServerStub.routes[path]=[(200,#"{"conversations":[{"id":"other-server","status":"done"}],"next_cursor":null}"#)]
  await v.reappear();#expect(v.result?.conversations.first?.id=="other-server")
 }
 @Test func anUnchangedErrorStaysAndRetryAsksAgain() async throws {
  let(m,root)=try RetryFlowTests().model();defer{try? FileManager.default.removeItem(at:root)}
  await m.refreshServer();AppServerStub.routes[path]=[(503,#"{"error":"busy","detail":"synthetic transient outage"}"#)]
  let v=ExtractedSearchState(m);await v.reappear();try #require(v.error != nil)
  let before=AppServerStub.requests.filter{$0.path==path}.count
  await v.reappear();#expect(v.error != nil && AppServerStub.requests.filter{$0.path==path}.count==before)
  AppServerStub.routes[path]=[(200,#"{"conversations":[{"id":"retried","status":"done"}],"next_cursor":null}"#)]
  await v.retry();#expect(v.error==nil && v.result?.conversations.first?.id=="retried")
 }
 @Test func aRefreshKeepsTheShownResultsUntilTheNewAnswer() async throws {
  let(m,root)=try RetryFlowTests().model();defer{try? FileManager.default.removeItem(at:root)}
  await m.refreshServer();AppServerStub.routes[path]=[(200,#"{"conversations":[{"id":"first","status":"done"}],"next_cursor":null}"#)]
  let v=ExtractedSearchState(m);await v.reappear();try #require(v.result?.conversations.first?.id=="first")
  #expect(AppModel.searchRerun(answered:"q",answeredRevision:1,question:"q",revision:2,hasResult:true,hasError:false) == .refresh)
  #expect(AppModel.searchRerun(answered:"q",answeredRevision:1,question:"q",revision:2,hasResult:false,hasError:true) == .fresh)
  #expect(AppModel.searchRerun(answered:"q",answeredRevision:2,question:"q",revision:2,hasResult:false,hasError:true) == .keep)
  #expect(AppModel.searchRerun(answered:"p",answeredRevision:2,question:"q",revision:2,hasResult:true,hasError:false) == .fresh)
 }
 @Test func searchLoggingIsRateLimitedAndContainsNoSearchContent() {
  SearchLog.reset();let now=Date();let marker="r3-rate-probe-event"
  let before=OmiLog.shared.recent().filter{$0.category=="search" && $0.message.hasPrefix(marker)}.count
  for i in 0..<20 {SearchLog.line(marker,"safe count",now:now.addingTimeInterval(Double(i)/100))}
  SearchLog.line(marker,"safe count",now:now.addingTimeInterval(1))
  #expect(OmiLog.shared.recent().filter{$0.category=="search" && $0.message.hasPrefix(marker)}.count-before==2)
  #expect(OmiLog.isDiagnostic(.info,"search"))
 }
}
}
