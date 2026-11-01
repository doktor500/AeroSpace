public let stableAeroSpaceAppId: String = "bobko.aerospace"
#if SPACE_CUBE
    // Built as Space Cube's embedded window engine (-Xswiftc -DSPACE_CUBE). Its own id gives
    // it its own socket, so it never talks to, or clashes with, a separately installed AeroSpace.
    public let aeroSpaceAppId: String = "dev.kenfos.space-cube.engine"
    public let aeroSpaceAppName: String = "Space Cube"
#elseif DEBUG
    public let aeroSpaceAppId: String = "bobko.aerospace.debug"
    public let aeroSpaceAppName: String = "AeroSpace-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "AeroSpace"
#endif
