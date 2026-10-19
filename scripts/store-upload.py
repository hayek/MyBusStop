#!/usr/bin/env python3
"""Uploads the App Store set that scripts/store-art.py made to every localization of a version.

    scripts/store-upload.py --app-id 6814983455 --version 0.1
    scripts/store-upload.py --app-id 6814983455 --version 0.1 --locales he en-US --devices iphone

The iPhone and iPad media go to the iOS version, the Mac's to the macOS one, the Apple TV's
(scripts/screenshots.sh store with STORE_DEVICES=tv; no preview) to the tvOS one, and the Apple
Watch's (STORE_DEVICES=watch; no preview) to the iOS one, whose app carries the watch app. Each store locale takes the screenshots and preview of the app language it is read in (es-MX and
es-ES share Spanish, fr-CA and fr-FR French, no is Bokmål). Uses the `asc` CLI and its saved
credentials. A set that already holds uploads is left as it is, unless --replace names its kind:
`asc` cannot delete, so those are deleted through the App Store Connect API directly, with a
token signed by the same key.
"""
import argparse, base64, json, os, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FINAL = ROOT / "screenshots/store/final"
ASC = "asc" if subprocess.run(["which", "asc"], capture_output=True).returncode == 0 else "asccli"

LANGUAGE = {
    "en-US": "en", "ar-SA": "ar", "de-DE": "de", "es-ES": "es", "es-MX": "es", "fi": "fi", "fr-FR": "fr",
    "fr-CA": "fr", "he": "he", "hi": "hi", "it": "it", "ja": "ja", "ko": "ko", "no": "nb", "pa-IN": "pa",
    "pl": "pl", "pt-BR": "pt-BR", "pt-PT": "pt-PT", "ru": "ru", "sv": "sv", "tr": "tr", "vi": "vi",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}
# App Store Connect's slots for the 6.9" iPhone, the 13" iPad, the Mac, the Apple TV and the Apple
# Watch Ultra (422 × 514, which stands in for every watch), and the version each belongs to.
SCREENSHOT_TYPE = {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129", "mac": "APP_DESKTOP", "tv": "APP_APPLE_TV",
                   "watch": "APP_WATCH_ULTRA"}
PREVIEW_TYPE = {"iphone": "IPHONE_67", "ipad": "IPAD_PRO_3GEN_129", "mac": "DESKTOP", "tv": "APPLE_TV"}
PLATFORM = {"iphone": "IOS", "ipad": "IOS", "mac": "MAC_OS", "tv": "TV_OS", "watch": "IOS"}
# The preview's poster frame: the opening live map, the bus at NOW and the headline in place.
POSTER = "00:00:02"


def asc(*args):
    result = subprocess.run([ASC, *args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"asc {' '.join(args[:2])}: {(result.stdout + result.stderr).strip()[:400]}")
    return json.loads(result.stdout).get("data", []) if result.stdout.strip() else []


def api_delete(kind, identifier):
    """DELETE /v1/<kind>/<id>, which `asc` has no command for."""
    request = urllib.request.Request(f"https://api.appstoreconnect.apple.com/v1/{kind}/{identifier}", method="DELETE",
                                     headers={"Authorization": f"Bearer {token()}"})
    urllib.request.urlopen(request).close()


def token():
    """An ES256 JWT for the account `asc` uses, signed with openssl (no third-party modules)."""
    credentials = json.loads(Path("~/.asc/credentials.json").expanduser().read_text())
    account = credentials["accounts"][credentials["active"]]
    b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=")
    header = b64(json.dumps({"alg": "ES256", "kid": account["keyID"], "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": account["issuerID"], "iat": int(time.time()), "exp": int(time.time()) + 600,
                             "aud": "appstoreconnect-v1"}).encode())
    with tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False) as key:
        os.chmod(key.name, 0o600)
        key.write(account["privateKeyPEM"])
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key.name], input=header + b"." + claims,
                             capture_output=True, check=True).stdout
    finally:
        os.unlink(key.name)
    # The DER signature is SEQUENCE { INTEGER r, INTEGER s }; a JWT wants r and s as 32 bytes each.
    def integer(at):
        length = der[at + 1]
        return der[at + 2:at + 2 + length], at + 2 + length
    r, after = integer(2)
    s, _ = integer(after)
    signature = r.lstrip(b"\0").rjust(32, b"\0") + s.lstrip(b"\0").rjust(32, b"\0")
    return (header + b"." + claims + b"." + b64(signature)).decode()


def version_id(app_id, version, platform):
    for v in asc("versions", "list", "--app-id", app_id):
        if v.get("versionString") == version and v.get("platform", "").upper().replace("MACOS", "MAC_OS") == platform:
            return v["id"]
    sys.exit(f"No {platform} version {version} for app {app_id}")


def find_or_create(existing, key, value, create):
    return next((s for s in existing if s.get(key) == value), None) or create()[0]


def upload(localization, locale, device, replace=()):
    folder = FINAL / device / LANGUAGE[locale]
    shots = sorted(folder.glob("[0-9][0-9]-*.png"))
    if not shots:
        print(f"{locale} {device}: nothing in {folder.relative_to(ROOT)}; run scripts/store-art.py")
        return

    sets = asc("screenshot-sets", "list", "--localization-id", localization)
    shot_set = find_or_create(sets, "screenshotDisplayType", SCREENSHOT_TYPE[device], lambda: asc(
        "screenshot-sets", "create", "--localization-id", localization, "--display-type", SCREENSHOT_TYPE[device]))
    existing = asc("screenshots", "list", "--set-id", shot_set["id"])
    if existing and "screenshots" in replace:
        for shot in existing:
            api_delete("appScreenshots", shot["id"])
        existing = []
    if existing:
        print(f"{locale} {device}: screenshots already there, left as they are")
    else:
        for shot in shots:
            asc("screenshots", "upload", "--set-id", shot_set["id"], "--file", str(shot), "--timeout", "5m")
        print(f"{locale} {device}: {len(shots)} screenshots")

    preview = folder / "preview.mp4"
    if not preview.exists():
        return
    previews = asc("app-preview-sets", "list", "--localization-id", localization)
    preview_set = find_or_create(previews, "previewType", PREVIEW_TYPE[device], lambda: asc(
        "app-preview-sets", "create", "--localization-id", localization, "--preview-type", PREVIEW_TYPE[device]))
    existing = asc("app-previews", "list", "--set-id", preview_set["id"])
    if existing and "previews" in replace:
        for clip in existing:
            api_delete("appPreviews", clip["id"])
        existing = []
    if existing:
        print(f"{locale} {device}: preview already there, left as it is")
    else:
        asc("app-previews", "upload", "--set-id", preview_set["id"], "--file", str(preview),
            "--preview-frame-time-code", POSTER, "--timeout", "10m")
        print(f"{locale} {device}: preview")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--locales", nargs="*")
    parser.add_argument("--devices", nargs="*", default=["iphone", "ipad", "mac"])
    parser.add_argument("--replace", nargs="*", default=[], choices=["screenshots", "previews"],
                        help="delete what a set already holds and upload again")
    args = parser.parse_args()
    localizations = {}
    for platform in {PLATFORM[d] for d in args.devices}:
        localizations[platform] = {l["locale"]: l["id"] for l in asc(
            "version-localizations", "list", "--version-id", version_id(args.app_id, args.version, platform))}
    failed = []
    for locale in args.locales or sorted(LANGUAGE):
        for device in args.devices:
            localization = localizations[PLATFORM[device]].get(locale)
            if not localization:
                print(f"{locale} {device}: no such localization, skipped")
                continue
            try:
                upload(localization, locale, device, args.replace)
            except RuntimeError as error:
                failed.append(f"{locale} {device}: {error}")
                print(failed[-1])
    if failed:
        sys.exit(f"{len(failed)} failed")


if __name__ == "__main__":
    main()
