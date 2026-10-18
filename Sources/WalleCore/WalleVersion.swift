/// The single source of truth for the walle version.
///
/// `scripts/build.sh` reads `string` out of this file to stamp the release
/// archive and `Walle.app/Contents/Info.plist`, so the CLI, the app bundle and
/// the Git tag cannot drift apart. A packager that already knows the version
/// can override it with `--version` / `WALLE_VERSION`; everything else follows
/// from here.
public enum WalleVersion {
    public static let string = "1.1.0"
}
