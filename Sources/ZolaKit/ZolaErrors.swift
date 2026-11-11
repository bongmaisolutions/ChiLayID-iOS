import Foundation

public enum ZolaError: LocalizedError, Sendable, Equatable {
    case sessionExpired(code: Int, endpoint: String, message: String)
    case apiError(code: Int, endpoint: String, message: String)
    case missingField(String)
    case crypto(String)
    case safetyGate(String)
    case groupSendNotSupportedOverHttp
    case transport(String)
    case keychain(Int32)
    case invalidArgument(String)
    case server(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case let .sessionExpired(_, _, message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                return "Phiên đăng nhập Zalo đã hết hạn. Vui lòng đăng nhập lại."
            }
            return "Phiên đăng nhập Zalo đã hết hạn (\(clean)). Vui lòng đăng nhập lại."
        case let .apiError(code, _, message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "Zalo từ chối yêu cầu (mã \(code))." : "\(clean) (mã \(code))"
        case let .missingField(field):
            return "Thiếu dữ liệu phiên bắt buộc (\(field))."
        case .crypto:
            return "Chưa thể hoàn tất đồng bộ bảo mật cho tài khoản này. Vui lòng đăng nhập lại hoặc thử lại sau."
        case let .safetyGate(detail):
            return detail
        case .groupSendNotSupportedOverHttp:
            return "Nhắn tin vào nhóm sẽ sớm được cập nhật trong bản tới."
        case .transport:
            return "Không thể kết nối máy chủ Zalo. Vui lòng kiểm tra mạng và thử lại."
        case .keychain:
            return "Không thể truy cập bộ nhớ bảo mật trên thiết bị."
        case let .invalidArgument(detail):
            return detail
        case let .server(code, message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "Zalo từ chối yêu cầu (mã \(code))." : "\(clean) (mã \(code))"
        }
    }
}
