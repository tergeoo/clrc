# Protocol fixtures

Golden control messages shared by the three implementations of the clrc
protocol (`relay/`, `agent/`, the iOS app + `ClrcCore`). There is no shared
code package, so these files are the contract: each side has tests that
encode or decode them.

| Fixture | Produced by | Consumed by | Tests |
|---|---|---|---|
| `register.json` | agent | relay | `agent/protocol_contract_test.go`, `relay/protocol_contract_test.go` |
| `agent_list.json` | relay | iOS | `relay/protocol_contract_test.go`, `ClrcCoreTests/ProtocolContractTests.swift` |
| `connect.json` | iOS | agent | `agent/protocol_contract_test.go` |
| `profiles_list_result.json` | agent | iOS | `agent/protocol_contract_test.go`, `ClrcCoreTests/LaunchProfileTests.swift` |
| `sessions_list.json` | agent | iOS | `agent/protocol_contract_test.go`, `ClrcCoreTests/ProtocolContractTests.swift` |

Changing a message: edit the fixture first, watch the tests on every side
fail, then update each implementation. Decoders reject unknown fields in
these tests, so a field added on one side only is caught.
