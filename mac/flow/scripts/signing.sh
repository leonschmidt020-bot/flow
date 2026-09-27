#!/bin/bash
# Flow – Signatur-Identität finden (wird von build.sh, setup.sh und ../clipvault/build.sh mit `source` geladen).
#
# WARUM NICHT AD-HOC („codesign -s -“)?
#   macOS merkt sich Mikrofon, Bedienungshilfen und Eingabeüberwachung pro „designated requirement“ (DR) der App.
#   Bei Ad-hoc-Signatur ist die DR nur der cdhash = Prüfsumme der Binary → JEDER Neubau ist für macOS eine neue App:
#   Freigaben greifen nicht mehr (Bedienungshilfen steht noch „an“ in der Liste, wirkt aber nicht), fn geht nicht,
#   Einfügen geht nicht. Mit einem Zertifikat lautet die DR „Bundle-ID + dieses Zertifikat“ → bleibt über alle
#   Neubauten und Updates gleich, die Freigaben bleiben.
#
# Reihenfolge (die erste passende gewinnt):
#   1. FLOW_SIGN_IDENTITY (SHA-1, Name – z. B. dein eigenes „Apple Development: …“ – oder „-“ = ad-hoc mit Warnung)
#   2. Die Identität, mit der die installierte App schon signiert ist (sonst verliert man beim Wechsel alle Freigaben)
#   3. Eigenes, lokales Zertifikat „Flow Local Signing“ (einmal im Anmelde-Schlüsselbund angelegt, 10 Jahre gültig,
#      nur auf diesem Mac, kein Apple-Konto nötig, kein sudo)
#   Klappt nichts davon, bricht choose_sign_identity mit 1 ab – build.sh nimmt dann ad-hoc und warnt deutlich.
#
# Ergebnis: SIGN_IDENTITY (SHA-1 oder „-“), SIGN_LABEL (lesbar)
#
# FLOW_KEYCHAIN=<datei>: nur für Tests – eigener Schlüsselbund statt login (für die Dauer des Signierens in der
# Suchliste, danach wiederhergestellt). FLOW_KEYCHAIN_PASSWORD entsperrt ihn.

LOCAL_CERT_NAME="${FLOW_LOCAL_CERT_NAME:-Flow Local Signing}"
SIGN_KC="${FLOW_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
_SIGN_SAVED_LIST=""

# codesign findet Identitäten nur in der Suchliste: ein Test-Schlüsselbund wird kurz angehängt und danach
# wird die ursprüngliche Liste wiederhergestellt (codesign --keychain reicht nicht, gemessen 27.09.2026).
sign_keychain_begin() {
  [ -z "${FLOW_KEYCHAIN:-}" ] && return 0
  _SIGN_SAVED_LIST="$(security list-keychains -d user | tr -d '"' | xargs)"
  # shellcheck disable=SC2086
  security list-keychains -d user -s $_SIGN_SAVED_LIST "$SIGN_KC"
  [ -n "${FLOW_KEYCHAIN_PASSWORD:-}" ] && security unlock-keychain -p "$FLOW_KEYCHAIN_PASSWORD" "$SIGN_KC"
  return 0
}
sign_keychain_end() {
  [ -z "${FLOW_KEYCHAIN:-}" ] || [ -z "$_SIGN_SAVED_LIST" ] && return 0
  # shellcheck disable=SC2086
  security list-keychains -d user -s $_SIGN_SAVED_LIST
  _SIGN_SAVED_LIST=""
}

# Hash einer Identität per Namen (auch nicht-vertrauenswürdige selbst signierte – codesign kann sie benutzen)
_sig_hash_by_name() {   # $1 = Name (Teilstring), $2 = "valid" für nur gültige
  local flag=""; [ "${2:-}" = "valid" ] && flag="-v"
  security find-identity $flag -p codesigning ${FLOW_KEYCHAIN:+"$SIGN_KC"} 2>/dev/null \
    | grep -F "\"$1" | head -1 | awk '{print $2}'
}

# Bereits vorhandene lokale Identität?
local_identity_hash() { _sig_hash_by_name "$LOCAL_CERT_NAME"; }

# Lokales Code-Signing-Zertifikat anlegen (einmalig). Kein sudo, kein Vertrauens-Eintrag nötig.
create_local_identity() {
  local tmp pw ossl legacy=""
  tmp="$(mktemp -d)"; pw="$(/usr/bin/openssl rand -hex 16)"
  ossl=/usr/bin/openssl   # LibreSSL von macOS: erzeugt .p12, das `security import` lesen kann
  $ossl version | grep -q "^OpenSSL 3" && legacy="-legacy"
  cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $LOCAL_CERT_NAME
O = Flow (lokal auf diesem Mac)
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CFG
  $ossl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$tmp/cfg" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  $ossl pkcs12 -export $legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$LOCAL_CERT_NAME" \
      -out "$tmp/id.p12" -passout "pass:$pw" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  # -T /usr/bin/codesign: nur codesign darf den Schlüssel ohne Nachfrage benutzen
  security import "$tmp/id.p12" -k "$SIGN_KC" -P "$pw" -T /usr/bin/codesign >/dev/null || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  # Partitionsliste setzen = keine „codesign möchte auf den Schlüssel zugreifen“-Dialoge.
  # Braucht das Passwort des Schlüsselbunds (bei login = Mac-Passwort). Ohne: macOS fragt beim ersten Signieren
  # einmal nach → „Immer erlauben“ klicken.
  local kcpw="${FLOW_KEYCHAIN_PASSWORD:-}"
  if [ -z "$kcpw" ] && [ -t 0 ] && [ -z "${FLOW_KEYCHAIN:-}" ]; then
    echo "   Einmalig: Mac-Passwort, damit codesign den neuen Schlüssel ohne Rückfrage nutzen darf"
    echo "   (Enter = überspringen, dann beim ersten Signieren „Immer erlauben“ klicken)."
    read -r -s -p "   Passwort: " kcpw; echo
  fi
  if [ -n "$kcpw" ]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpw" -l "$LOCAL_CERT_NAME" "$SIGN_KC" >/dev/null 2>&1 \
      || security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpw" "$SIGN_KC" >/dev/null 2>&1 || true
  fi
  return 0
}

# Hauptfunktion. $1 = Pfad der installierten App (für „dieselbe Identität wie bisher“), $2 = "nocreate" (nur prüfen)
choose_sign_identity() {
  local installed="${1:-}" mode="${2:-}" h auth
  SIGN_IDENTITY=""; SIGN_LABEL=""
  # 1. ausdrücklich gesetzt
  if [ -n "${FLOW_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$FLOW_SIGN_IDENTITY"; SIGN_LABEL="FLOW_SIGN_IDENTITY=$FLOW_SIGN_IDENTITY"
    [ "$SIGN_IDENTITY" = "-" ] && SIGN_LABEL="ad-hoc (FLOW_SIGN_IDENTITY=-)"
    return 0
  fi
  # 2. dieselbe wie die installierte App
  if [ -n "$installed" ] && [ -d "$installed" ]; then
    auth="$(codesign -dvv "$installed" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-)"
    if [ -n "$auth" ]; then
      h="$(_sig_hash_by_name "$auth" valid)"; [ -z "$h" ] && h="$(_sig_hash_by_name "$auth")"
      if [ -n "$h" ]; then SIGN_IDENTITY="$h"; SIGN_LABEL="$auth (wie bisher)"; return 0; fi
    fi
  fi
  # 3. lokales Zertifikat (vorhanden oder neu)
  h="$(local_identity_hash)"
  if [ -z "$h" ] && [ "$mode" != "nocreate" ]; then
    echo "» Lege einmalig das lokale Signatur-Zertifikat „${LOCAL_CERT_NAME}“ im Schlüsselbund an …"
    create_local_identity && h="$(local_identity_hash)"
  fi
  if [ -n "$h" ]; then SIGN_IDENTITY="$h"; SIGN_LABEL="$LOCAL_CERT_NAME (lokal)"; return 0; fi
  [ "$mode" = "nocreate" ] && { SIGN_LABEL="(würde „${LOCAL_CERT_NAME}“ anlegen)"; return 1; }
  return 1
}

# Warnung, wenn nur ad-hoc signiert werden kann (Freigaben gehen bei jedem Neubau verloren)
warn_adhoc() {   # $1 = App-Name
  echo "⚠︎  AD-HOC-SIGNATUR für ${1}: macOS erkennt die App nach jedem Neubau/Update als NEUE App."
  echo "   Mikrofon / Bedienungshilfen / Eingabeüberwachung müssen dann jedes Mal neu erteilt werden"
  echo "   (Eintrag in der Liste entfernen (–) und neu hinzufügen). Besser: ./setup.sh legt „${LOCAL_CERT_NAME}“ an."
}
