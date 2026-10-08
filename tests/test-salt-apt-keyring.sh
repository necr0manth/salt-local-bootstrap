#!/usr/bin/env bash
# Run with: bash tests/test-salt-apt-keyring.sh
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "$repo_dir/.salt-keyring-test.XXXXXX")"
export GNUPGHOME="$test_root/gnupg"
mkdir -m 700 "$GNUPGHOME" "$test_root/verifier"

cleanup() {
  rm -r -- "$test_root"
}
trap cleanup EXIT

test_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in gpg gpgv; do
  command -v "$tool" >/dev/null 2>&1 || test_fail "$tool is required"
done

# Load functions without executing the bootstrap's final entrypoint. Leave the
# production entrypoint intact: the bootstrap also supports execution via a pipe.
[ "$(tail -n 1 "$repo_dir/salt-local-bootstrap.sh")" = 'main "$@"' ] \
  || test_fail 'The bootstrap entrypoint changed; update the test loader'
sed '$d' "$repo_dir/salt-local-bootstrap.sh" > "$test_root/bootstrap-functions.sh"
# shellcheck source=../salt-local-bootstrap.sh
source "$test_root/bootstrap-functions.sh"
declare -F repair_salt_apt_keyring >/dev/null \
  || test_fail 'repair_salt_apt_keyring is missing'

# Never allow privileged operations or writes outside the temporary fixtures.
run_root() {
  [ "$1" = install ] || test_fail "Unexpected root command: $1"
  local arg
  for arg in "${@:2}"; do
    case "$arg" in
      "$test_root"/*|-*|644|0644) ;;
      *) test_fail "install argument escaped the fixture: $arg" ;;
    esac
  done
  printf '%s\n' "$*" >> "$root_calls"
  "$@"
}

fixture() {
  case_dir="$test_root/$1"
  keyring_dir="$case_dir/keyrings"
  sources_file="$case_dir/salt.sources"
  work_dir="$case_dir/work"
  root_calls="$case_dir/root-calls"
  mkdir -p "$keyring_dir" "$work_dir"
  : > "$root_calls"
}

write_sources() {
  cat > "$1" <<EOF
# Preserve comments, repository options, and stanza spacing.
Types: deb
URIs: https://packages.broadcom.com/artifactory/saltproject-deb
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: $2
Enabled: yes
# Signed-By: /etc/apt/keyrings/salt-archive-keyring.pgp

EOF
}

assert_same() {
  cmp -s "$1" "$2" || test_fail "$2 differs from $1"
}

assert_no_installs() {
  [ ! -s "$root_calls" ] || test_fail 'A no-op unexpectedly installed files'
}

assert_usable_keyring() {
  local keyring="$keyring_dir/salt-archive-keyring.gpg"
  assert_same "$test_root/current.gpg" "$keyring"
  [ "$(stat -c '%a' "$keyring")" = 644 ] \
    || test_fail 'The repaired keyring is not readable with mode 0644'
  gpgv --homedir "$test_root/verifier" --keyring "$keyring" \
    "$test_root/Release.gpg" "$test_root/Release" > "$case_dir/verify.log" 2>&1 \
    || { cat "$case_dir/verify.log" >&2; test_fail 'The repaired keyring cannot verify Release'; }
}

repair() {
  repair_salt_apt_keyring "$keyring_dir" "$sources_file" "$work_dir"
}

# Public-only fixtures generated for this test. The signature verifies with the
# current key but not the stale key. Embedded fixtures avoid a dependency on a
# running gpg-agent or access to its sockets. No private key is stored.
cat > "$test_root/current.asc" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

xsBNBGVT8QABCADSytw+Y92MUNvbSEEy5wGyhQvT4/ZHi0n6hN3GmoEVxA3A7qu8
3oUBFTtPHsg/o2YNUQvJZr/i86NNnDud3o57nXpT8IezJJcqwDuWykXtwzr1vy7E
IYuIe1iWmrmbXZ7jAnS5Re5pJOqeOuvroDa5ZkR2i7H90AQpKe08p1uNZfko1d0H
+PAx2RE3+9f60yAy3Ql2ORfV8E3qzK6haJaD7PcspaaOv1CknZb0iQ0l4j2dGliw
Et8XYvKet2l+NWzPPYztRFtd8tEddhNzD5+TrSUly62HhSB6IC44igPTyq5LYs2g
eL6yXVKpIrf3e1yzB4bp4XrpGopQQeAkQc8jABEBAAHNOVNhbHQga2V5cmluZyBy
ZWdyZXNzaW9uIGZpeHR1cmUgPGN1cnJlbnRAZXhhbXBsZS5pbnZhbGlkPsLAdgQT
AQgAIAUCZVPxABYhBBp/ocMv9EARd70wBkNiihbe8r/dAhsDAAoJEENiihbe8r/d
3mUIAMAMzUQxvkzMZZ35yztI0RgdeCEiv4TMPhsHRrE29XGmTjDxaMdNlIwTu2mc
Bp0x/2b1+YWgPx2wiSxF3snSEL1sXDJsh7O9XLhsBAftKMFEvlAKoFUKc7k89F5w
eptTtTWy/BMPC1FDHFwUZz7dCd89799P2RqIP8RsqQV912Ch/5AEezm3DNQMguVq
cgslKjjFV8rBqfrX0qhxKCZ22fBipxt5osBd1iZVY/OZMIeiYZYnwxRvWjrrCNaV
hsBQ1ejzCgX9anBu8xfsO8QCokWIxskZNiJ6JQ19JaySPK5QxskB4KiOT3YwYRts
NXMQEkwU64WPoyH44MD4DZeF1C4=
=mOle
-----END PGP PUBLIC KEY BLOCK-----
EOF
cat > "$test_root/stale.asc" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

xsBNBGVT8QABCACwk0HtEH6UKvBy6yyRSw2njS8zWbyK0jxUlzASo785FGXkb3/x
P7Aril8WfbF19R5Ri6ZrYelwWc0IHpbqVEC7WWRG/PjTkzDKgWig7fcQ644zJvha
SFJjfu8BiXCsXuQv0pw+ibdHZtPyJVlrJLsbVPqfGoWNaC5gJ9+OC9XTjhmWmWsy
SrOB5uM2ZrlSk2fwqWl59J+3KjaVrOmiwivhU+57WCq2/gxritLN7wXxOFYB7hED
SiaC8bsWmo0hvPLM9BrpMcYDMLuSS8ZwBi0Ag16gBcOcJRtcve+gVxJDzP5EkESn
k2u6RHaTZbVo2eF9541TZA1No5E6JPAT15udABEBAAHNN1NhbHQga2V5cmluZyBy
ZWdyZXNzaW9uIGZpeHR1cmUgPHN0YWxlQGV4YW1wbGUuaW52YWxpZD7CwHYEEwEI
ACAFAmVT8QAWIQSK5A4oGGUjFhVqSPqgPb6UToWUiwIbAwAKCRCgPb6UToWUi6qt
B/421340TlEiu9pfV9DG2zTiRBIMfqUV2UG2AbZ1HEPqZ1vZ9sWkIepH/H50i6Pf
6OCD9MlLhKG75OKg3QhTLD+FiNszZeBpGTCQnX7Gsm/DS5cjn4c2JqgTR7i/X+MX
J2CzgvTFfQiiFkM40mMqDBfZOWGD8JeNI+lPHe9rd7dDQl/cJvpdsIBqzhdBYD+a
lxBSVAhqM7L/vxuE9u9YqAKT4yqENdEFMFJ2hthbwymkcg3HZ0S4Dj1qlifted6c
nJ3wbjonl42HpfOwdRJTk0RxhNpT/4xCmH/GzBCuJpWKYKp7MTQpAJ5rDWMyQiVz
ZpdZH1oCwQTbMY2LIKHXu0nE
=VJ5K
-----END PGP PUBLIC KEY BLOCK-----
EOF
cat > "$test_root/Release.asc" <<'EOF'
-----BEGIN PGP SIGNATURE-----

wsBzBAABCAAdBQJlU/EAFiEEGn+hwy/0QBF3vTAGQ2KKFt7yv90ACgkQQ2KKFt7y
v92uIQf/dd5rTmTLZnWsiNPbxzh1TxdTksArzd30QqWTurLt+cceS2Dl6imO0RUW
bgsYloY5yjnUBBt/vwcpzigehpSOk5UEYQz+glih2TqgC7mvm1DZdXvNQ7qhZ7ob
4VyLi6WYf8Au0Sdul3PDORoaHZw0ZdWU839COZJK6PeJTI0gF7GjGTeWxpAuk1FM
WAsT2PJqQ2VTzl67KMn6KNNqQkTs0amEk34p9E+iCiaFwIqphen3COyLR5Eg/0VK
VYUL+9pr5FikghvkDOdXyk32su8ruu5wxQe2sXSqy0Erl6wrahiRPnBn6rZ0teoT
rSlqTqeWnhIyINwRo4uf2AYL2lMDUg==
=qu9G
-----END PGP SIGNATURE-----
EOF
printf 'Origin: Salt keyring regression fixture\nSuite: stable\n' > "$test_root/Release"
for name in current stale Release; do
  gpg --no-options --batch --dearmor --output "$test_root/$name.gpg" "$test_root/$name.asc"
done
chmod 644 "$test_root/current.gpg" "$test_root/stale.gpg"

legacy_source=/etc/apt/keyrings/salt-archive-keyring.pgp
current_source=/etc/apt/keyrings/salt-archive-keyring.gpg

test_fresh_install() {
  fixture fresh
  repair
  [ ! -e "$sources_file" ] || test_fail 'Fresh install created a sources file'
  [ ! -e "$keyring_dir/salt-archive-keyring.gpg" ] || test_fail 'Fresh install created a keyring'
  assert_no_installs

  write_sources "$sources_file" "$legacy_source"
  cp "$sources_file" "$case_dir/original.sources"
  repair
  assert_same "$case_dir/original.sources" "$sources_file"
  [ ! -e "$keyring_dir/salt-archive-keyring.gpg" ] || test_fail 'Missing key created a keyring'
  assert_no_installs
}

test_legacy_armored() {
  fixture legacy-armored
  write_sources "$sources_file" "$legacy_source"
  write_sources "$case_dir/expected.sources" "$current_source"
  cp "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  repair
  assert_same "$case_dir/expected.sources" "$sources_file"
  assert_same "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  assert_usable_keyring
}

test_already_correct() {
  fixture already-correct
  write_sources "$sources_file" "$current_source"
  cp "$sources_file" "$case_dir/original.sources"
  cp "$test_root/current.gpg" "$keyring_dir/salt-archive-keyring.gpg"
  cp "$test_root/stale.asc" "$keyring_dir/salt-archive-keyring.pgp"
  repair
  assert_same "$case_dir/original.sources" "$sources_file"
  assert_same "$test_root/stale.asc" "$keyring_dir/salt-archive-keyring.pgp"
  assert_usable_keyring
  assert_no_installs
}

test_missing_current_keyring() {
  fixture missing-current
  write_sources "$sources_file" "$current_source"
  cp "$sources_file" "$case_dir/original.sources"
  cp "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  repair
  assert_same "$case_dir/original.sources" "$sources_file"
  assert_same "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  assert_usable_keyring
  [ "$(wc -l < "$root_calls")" -eq 1 ] || test_fail 'Recovery rewrote the current sources file'
}

test_malformed_armor() {
  fixture malformed-armor
  write_sources "$sources_file" "$legacy_source"
  cp "$sources_file" "$case_dir/original.sources"
  cp "$test_root/stale.gpg" "$keyring_dir/salt-archive-keyring.gpg"
  cat > "$keyring_dir/salt-archive-keyring.pgp" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

this-is-not-valid-base64!!!!
-----END PGP PUBLIC KEY BLOCK-----
EOF
  cp "$keyring_dir/salt-archive-keyring.pgp" "$case_dir/original.pgp"
  if (repair) > "$case_dir/repair.log" 2>&1; then
    test_fail 'Malformed ASCII armor was accepted'
  fi
  assert_same "$case_dir/original.sources" "$sources_file"
  assert_same "$case_dir/original.pgp" "$keyring_dir/salt-archive-keyring.pgp"
  assert_same "$test_root/stale.gpg" "$keyring_dir/salt-archive-keyring.gpg"
  assert_no_installs
}

test_custom_source() {
  fixture custom-source
  write_sources "$sources_file" /etc/apt/keyrings/custom-salt-keyring.gpg
  cp "$sources_file" "$case_dir/original.sources"
  cp "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  repair
  assert_same "$case_dir/original.sources" "$sources_file"
  assert_same "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  [ ! -e "$keyring_dir/salt-archive-keyring.gpg" ] || test_fail 'Custom source created a standard keyring'
  assert_no_installs
}

test_binary_legacy() {
  fixture binary-legacy
  write_sources "$sources_file" "$legacy_source"
  write_sources "$case_dir/expected.sources" "$current_source"
  cp "$test_root/current.gpg" "$keyring_dir/salt-archive-keyring.pgp"
  repair
  assert_same "$case_dir/expected.sources" "$sources_file"
  assert_same "$test_root/current.gpg" "$keyring_dir/salt-archive-keyring.pgp"
  assert_usable_keyring
}

test_armored_current() {
  fixture armored-current
  write_sources "$sources_file" "$current_source"
  cp "$sources_file" "$case_dir/original.sources"
  cp "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.gpg"
  repair
  assert_same "$case_dir/original.sources" "$sources_file"
  assert_usable_keyring
  [ "$(wc -l < "$root_calls")" -eq 1 ] || test_fail 'Conversion rewrote the current sources file'
}

test_active_legacy_precedence() {
  fixture legacy-precedence
  write_sources "$sources_file" "$legacy_source"
  write_sources "$case_dir/expected.sources" "$current_source"
  cp "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  cp "$test_root/stale.gpg" "$keyring_dir/salt-archive-keyring.gpg"
  repair
  assert_same "$case_dir/expected.sources" "$sources_file"
  assert_same "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
  assert_usable_keyring
}

test_unmanaged_stanzas() {
  local variant
  for variant in disabled unrelated multiple-signers; do
    fixture "$variant"
    write_sources "$case_dir/base.sources" "$legacy_source"
    case "$variant" in
      disabled) sed 's/^Enabled: yes$/Enabled: no/' "$case_dir/base.sources" > "$sources_file" ;;
      unrelated) sed 's@https://packages.broadcom.com/artifactory/saltproject-deb@https://example.invalid/deb@' "$case_dir/base.sources" > "$sources_file" ;;
      multiple-signers)
        cp "$case_dir/base.sources" "$sources_file"
        printf 'Signed-By: /etc/apt/keyrings/custom.gpg\n' >> "$sources_file"
        ;;
    esac
    cp "$sources_file" "$case_dir/original.sources"
    cp "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
    repair
    assert_same "$case_dir/original.sources" "$sources_file"
    assert_same "$test_root/current.asc" "$keyring_dir/salt-archive-keyring.pgp"
    assert_no_installs
  done
}

for test_case in \
  test_fresh_install \
  test_legacy_armored \
  test_already_correct \
  test_missing_current_keyring \
  test_malformed_armor \
  test_custom_source \
  test_binary_legacy \
  test_armored_current \
  test_active_legacy_precedence \
  test_unmanaged_stanzas
do
  "$test_case"
  printf 'PASS: %s\n' "$test_case"
done
