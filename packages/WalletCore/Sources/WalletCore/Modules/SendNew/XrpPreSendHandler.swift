import Combine
import Foundation
import MarketKit
import RxSwift
import SwiftUI

final class XrpPreSendHandler {
    private let token: Token
    private let destination: String
    private let adapter: ISendXrpAdapter & IBalanceAdapter
    private let stateSubject = PassthroughSubject<AdapterState, Never>()
    private let balanceSubject = PassthroughSubject<Decimal, Never>()
    private let settingsSubject = PassthroughSubject<Bool, Never>()
    private let disposeBag = DisposeBag()
    private let embeddedDestinationTag: UInt32?

    private(set) var destinationTag: UInt32? {
        didSet { settingsSubject.send(settingsModified) }
    }

    init(token: Token, destination: String, adapter: ISendXrpAdapter & IBalanceAdapter) {
        self.token = token
        self.destination = destination
        self.adapter = adapter
        embeddedDestinationTag = try? XrpAddressCodec.decode(destination, network: .mainnet).destinationTag
        destinationTag = embeddedDestinationTag

        adapter.balanceStateUpdatedObservable
            .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .subscribe(onNext: { [weak self] in self?.stateSubject.send($0) })
            .disposed(by: disposeBag)

        adapter.balanceDataUpdatedObservable
            .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .subscribe(onNext: { [weak self] in self?.balanceSubject.send($0.available) })
            .disposed(by: disposeBag)
    }

    func setDestinationTag(_ tag: UInt32?) {
        guard embeddedDestinationTag == nil else { return }
        destinationTag = tag
    }
}

extension XrpPreSendHandler: IPreSendHandler {
    var hasSettings: Bool { embeddedDestinationTag == nil }
    var state: AdapterState { adapter.balanceState }
    var statePublisher: AnyPublisher<AdapterState, Never> { stateSubject.eraseToAnyPublisher() }
    var balance: Decimal { adapter.balanceData.available }
    var balancePublisher: AnyPublisher<Decimal, Never> { balanceSubject.eraseToAnyPublisher() }
    var settingsModified: Bool { embeddedDestinationTag == nil && destinationTag != nil }
    var settingsModifiedPublisher: AnyPublisher<Bool, Never> { settingsSubject.eraseToAnyPublisher() }

    func hasMemo(address _: String?) -> Bool { true }

    func settingsView(onChangeSettings: @escaping () -> Void) -> AnyView {
        AnyView(XrpDestinationTagSettingsView(handler: self, onChangeSettings: onChangeSettings))
    }

    func sendData(amount: Decimal, address: String, memo: String?) -> SendDataResult {
        do {
            _ = try XrpAmount.drops(amount)
            _ = try XrpAddressCodec.resolve(address, separateTag: destinationTag, network: .mainnet)
            if let memo, memo.utf8.count > 256 {
                throw XrpRuntimeError.memoTooLarge
            }
            return .valid(sendData: .xrp(
                token: token,
                amount: amount,
                destination: address,
                destinationTag: destinationTag,
                memo: memo,
                recommendedFeeDrops: nil,
                minimumSendAmountDrops: nil
            ))
        } catch {
            return .invalid(cautions: [CautionNew(text: Self.message(error), type: .error)])
        }
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case XrpCodecError.destinationTagConflict:
            return "The destination tag conflicts with the tag embedded in this X-address."
        case XrpCodecError.wrongNetwork:
            return "This XRP address belongs to a different network."
        case XrpRuntimeError.memoTooLarge:
            return "XRP memo data must be 256 bytes or less."
        default:
            return "Enter a valid mainnet XRP classic address or X-address."
        }
    }
}

private struct XrpDestinationTagSettingsView: View {
    let handler: XrpPreSendHandler
    let onChangeSettings: () -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var tagText: String
    @FocusState private var focused: Bool

    init(handler: XrpPreSendHandler, onChangeSettings: @escaping () -> Void) {
        self.handler = handler
        self.onChangeSettings = onChangeSettings
        _tagText = State(initialValue: handler.destinationTag.map(String.init) ?? "")
    }

    private var parsedTag: UInt32? {
        guard !tagText.isEmpty else { return nil }
        return try? XrpAddressCodec.destinationTag(decimalString: tagText)
    }

    private var valid: Bool { tagText.isEmpty || parsedTag != nil }

    var body: some View {
        ThemeNavigationStack {
            ThemeView {
                BottomGradientWrapper {
                    ScrollView {
                        VStack(alignment: .leading, spacing: .margin12) {
                            InputTextRow {
                                InputTextView(placeholder: "Destination tag (optional)", text: $tagText)
                                    .keyboardType(.numberPad)
                                    .autocorrectionDisabled()
                                    .focused($focused)
                            }
                            ThemeText("A destination tag routes XRP inside services and exchanges. Zero is a valid tag. It is separate from memo data.", style: .caption)
                        }
                        .padding(.margin16)
                    }
                    .onTapGesture { focused = false }
                } bottomContent: {
                    ThemeButton(text: "button.save".localized) {
                        handler.setDestinationTag(parsedTag)
                        onChangeSettings()
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .navigationTitle("XRP Destination Tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) { Image("close") }
                }
            }
        }
    }
}
