# Sourced by the build scripts: the code-signing identity every Umi build signs with.
#
# Builds sign with a stable local identity, never ad hoc: an ad-hoc signature changes with every
# build, and macOS then forgets the privacy permissions given to the app (Accessibility, Screen
# Recording, microphone…). The default is "Switcher Local Code Signing", a self-signed certificate
# in the login keychain of Alejo's main Mac; UMI_SIGN_IDENTITY names another one. A build fails
# when the identity isn't there.
umi_sign_identity="${UMI_SIGN_IDENTITY:-Switcher Local Code Signing}"

umi_require_sign_identity() {
    if [[ -z "$umi_sign_identity" || "$umi_sign_identity" == "-" ]]; then
        echo "Umi builds sign with a stable identity, never ad hoc; set UMI_SIGN_IDENTITY to one" >&2
        return 1
    fi
    if ! security find-identity -v -p codesigning | grep -qF "\"$umi_sign_identity\""; then
        echo "no code-signing identity \"$umi_sign_identity\" in the keychain (UMI_SIGN_IDENTITY names another)" >&2
        return 1
    fi
}
