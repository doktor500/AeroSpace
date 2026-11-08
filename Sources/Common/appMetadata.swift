import Foundation

public let stableAeroSpaceAppId: String = "bobko.aerospace"
#if AEROSPACE_EMBEDDED
    // Built to run inside another app (-Xswiftc -DAEROSPACE_EMBEDDED). Its own id gives it its
    // own socket, so it never talks to, or clashes with, a separately installed AeroSpace. It
    // goes by the name of the bundle it ships in.
    public let aeroSpaceAppId: String = "bobko.aerospace.embedded"
    public let aeroSpaceAppName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "AeroSpace"
#elseif DEBUG
    public let aeroSpaceAppId: String = "bobko.aerospace.debug"
    public let aeroSpaceAppName: String = "AeroSpace-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "AeroSpace"
#endif
