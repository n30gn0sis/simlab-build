#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-malcolm-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE/malcolm"
    cat > "$BUNDLE/malcolm/image-list.txt" <<'EOF'
ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
ghcr.io/idaholab/malcolm/zeek:0.0.0-fixture
EOF
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# Stub the docker CLI so the suite never touches a real daemon.
stub_docker_reporting() {
    { echo '#!/usr/bin/env bash'
      echo 'if [ "$1" = "image" ] && [ "$2" = "ls" ]; then'
      for t in "$@"; do echo "  echo '$t'"; done
      echo 'fi'
      echo 'exit 0'
    } > "$BATS_TEST_TMPDIR/bin/docker"
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

@test "assert-tags passes when every listed tag is present" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/zeek:0.0.0-fixture
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "assert-tags FAILS when a tag is missing, and names it" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zeek:0.0.0-fixture"* ]]
}

@test "assert-tags fails loudly when image-list.txt is missing" {
    rm "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"image-list.txt"* ]]
}

@test "a bundle directory that does not exist is rejected" {
    run "$SCRIPT" assert-tags /nonexistent
    [ "$status" -ne 0 ]
}

# --- Regressions -------------------------------------------------------------

@test "a missing image list never reports success" {
    # The subshell regression: when image_list ran inside `< <(...)`, its die()
    # exited only that subshell, the loop saw EOF, and the script printed
    # "all images present" for a bundle containing no list at all.
    rm "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [[ "$output" != *"all images present"* ]]
}

@test "an image list holding only comments fails loudly" {
    printf '# nothing but a comment\n\n' > "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"all images present"* ]]
}

@test "a nonexistent bundle is rejected for the right reason, not merely absent tooling" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
    run "$SCRIPT" assert-tags /nonexistent
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a directory"* ]]
}
