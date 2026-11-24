import SwiftUI
import SMSBackupCore

struct CallsView: View {
    @Environment(AppModel.self) private var model
    @State private var calls: [CallEntry] = []
    @State private var filter = ""
    @State private var selection = Set<CallEntry.ID>()

    private var reloadKey: String {
        "\(filter)|\(model.callFilter?.rawValue ?? "")|\(model.dataVersion)"
    }

    var body: some View {
        Table(calls, selection: $selection) {
            TableColumn("Date") { call in
                Text(call.date.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            }
            .width(min: 150, ideal: 180)
            TableColumn("Contact") { call in
                Text(call.contactName ?? "—")
            }
            TableColumn("Number") { call in
                Text(call.number).monospacedDigit().textSelection(.enabled)
            }
            TableColumn("Type") { call in
                Label(call.typeName, systemImage: symbol(call.type))
                    .foregroundStyle(call.type == 3 || call.type == 5 || call.type == 6 ? Color.red : Color.primary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Duration") { call in
                Text(Formatters.duration(call.duration)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter by name or number")
        .overlay {
            if calls.isEmpty {
                ContentUnavailableView("No Calls",
                                       systemImage: "phone",
                                       description: Text("Import a calls-*.xml backup to browse your call log."))
            }
        }
        .navigationTitle("Calls")
        .navigationSubtitle(model.callFilter?.rawValue ?? "")
        .task(id: reloadKey) { await load() }
    }

    private func symbol(_ type: Int) -> String {
        switch type {
        case 1: return "phone.arrow.down.left"
        case 2: return "phone.arrow.up.right"
        case 3: return "phone.down"
        case 4: return "recordingtape"
        case 5, 6: return "nosign"
        default: return "phone"
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        let text = filter
        let types = (model.callFilter ?? .all).types
        let result: [CallEntry] = await Task.detached(priority: .userInitiated) {
            if let types, types.count > 1 {
                var all: [CallEntry] = []
                for t in types { all += (try? store.calls(CallQuery(text: text, type: t, limit: 20_000))) ?? [] }
                return all.sorted { $0.date > $1.date }
            }
            return (try? store.calls(CallQuery(text: text, type: types?.first, limit: 20_000))) ?? []
        }.value
        calls = result
    }
}
