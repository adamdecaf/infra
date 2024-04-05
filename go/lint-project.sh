#!/bin/bash
set -e

gitleaks_version=8.17.0
golangci_version=latest
sqlvet_version=v1.1.5

# Set these to any non-blank value to disable the linter
disable_golangci=""
if [[ "$SKIP_GOLANGCI" != "" ]];
then
    disable_golangci="$SKIP_GOLANGCI"
fi

mkdir -p ./bin/

# Collect all our files for processing
MODNAME=$(go list .)
GOPKGS=($(go list ./...))
GOFILES=($(find . -type f -not -path "./nginx/*" -name '*.go' -not -name '*.pb.go' | grep -v client | grep -v vendor))

# Print (and capture) the host's Go version
GO_VERSION=$(go version | grep -Eo '[0-9]\.[0-9]+\.?[0-9]?')
echo "Detected Go version $GO_VERSION"

# Set OS_NAME if it's empty (local dev)
OS_NAME=$TRAVIS_OS_NAME
UNAME=$(uname -s | tr [:upper:] [:lower:])
if [[ "$OS_NAME" == "" ]]; then
    if [[ "$UNAME" == "darwin" ]]; then
        export OS_NAME=osx
    else
        export OS_NAME=linux
    fi
fi

echo "running go linters for $OS_NAME"

# Check gofmt
if [[ "$OS_NAME" != "windows" ]]; then
    set +e
    code=0
    for file in "${GOFILES[@]}"
    do
        # Go 1.17 introduced a migration with build constraints
        # and they offer a migration with gofmt
        # See https://go.googlesource.com/proposal/+/master/design/draft-gobuild.md#transition for more details
        if [[ "$file" == "./pkged.go" ]];
        then
            gofmt -s -w pkged.go
        fi

        # Check the file's formatting
        test -z $(gofmt -s -l $file)
        if [[ $? != 0 ]];
        then
            code=1
            echo "$file is not formatted"
        fi
    done
    set -e
    if [[ $code != 0 ]];
    then
        exit $code
    fi

    echo "finished gofmt check"
fi

# Would be set to 'moov-io' or 'moovfinancial'
org=$(go mod why | head -n1  | awk -F'/' '{print $2}')

# Reject moovfinancial dependencies in moov-io projects
if [[ "$org" == "moov-io" ]];
then
    # Fail our build if we find moovfinancial dependencies
    if go list -m all | grep moovfinancial;
    then
        echo "Found github.com/moovfinancial dependencies in OSS. Please remove"
        exit 1
    fi
fi

# Allow for build tags to be set
if [[ "$GOTAGS" != "" ]]; then
    GOLANGCI_TAGS=" --build-tags $GOTAGS "
    GOTAGS=" -tags $GOTAGS "
fi

GORACE='-race'
if [[ "$CGO_ENABLED" == "0" || "$GOOS" == "js" || "$GOARCH" == "wasm" ]];
then
    GORACE=''
fi
if [[ "$DISABLE_GORACE" != "" ]];
then
    GORACE=''
fi

# Build the source code (to discover compile errors prior to linting)
echo "Building Go source code"
go build $GORACE $GOTAGS $GOBUILD_FLAGS ./...
echo "SUCCESS: Go code built without errors"

# gitleaks (secret scanning, in-progress of a rollout)
run_gitleaks=true
if [[ "$OS_NAME" == "windows" ]]; then
    run_gitleaks=false
fi
if [[ "$org" != "moov-io" ]]; then
    run_gitleaks=false
fi
if [[ "$EXPERIMENTAL" == *"gitleaks"* ]]; then
    run_gitleaks=true
fi
if [[ "$DISABLE_GITLEAKS" != "" ]]; then
    run_gitleaks=false
fi
if [[ "$run_gitleaks" == "true" ]]; then
    wget -q -O gitleaks.tar.gz https://github.com/zricethezav/gitleaks/releases/download/v"$gitleaks_version"/gitleaks_"$gitleaks_version"_"$UNAME"_x64.tar.gz
    tar xf gitleaks.tar.gz gitleaks
    mv gitleaks ./bin/gitleaks

    echo "gitleaks version: "$(./bin/gitleaks version)
    ./bin/gitleaks detect --no-git --verbose
    echo "FINISHED gitleaks check"
fi

## Run govulncheck which parses the compiled/used code for known vulnerabilities.
run_govulncheck=true
if [[ "$DISABLE_GOVULNCHECK" != "" ]]; then
    run_govulncheck=false
fi
if [[ "$SKIP_LINTERS" != "" ]]; then
    run_govulncheck=false
fi
if [[ "$run_govulncheck" == "true" ]]; then
    echo "STARTING govulncheck check"

    # Install the latest govulncheck release
    go install golang.org/x/vuln/cmd/govulncheck@latest

    # Find govulncheck
    bin=""
    if which -s govulncheck > /dev/null;
    then
        bin=$(which govulncheck 2>&1 | head -n1)
    fi
    # Public Github runners path
    actions_path="/home/runner/go/bin/govulncheck"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi
    # Moov hosted runner paths
    actions_path="/home/actions/bin/govulncheck"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi

    # Run govulncheck
    if [[ "$bin" != "" ]];
    then
        "$bin" -test ./...
        echo "FINISHED govulncheck check"
    else
        echo "Can't find govulncheck..."
    fi
fi

# sqlvet
if [[ "$EXPERIMENTAL" == *"sqlvet"* ]]; then
    # Download only on linux or macOS
    if [[ "$OS_NAME" != "windows" ]]; then
        if [[ "$OS_NAME" == "linux" ]]; then wget -q -O sqlvet.tar.gz https://github.com/houqp/sqlvet/releases/download/"$sqlvet_version"/sqlvet-"$sqlvet_version"-linux-amd64.tar.gz; fi
        if [[ "$OS_NAME" == "osx" ]]; then wget -q -O sqlvet.tar.gz https://github.com/houqp/sqlvet/releases/download/"$sqlvet_version"/sqlvet-"$sqlvet_version"-darwin-amd64.tar.gz; fi
        tar xf sqlvet.tar.gz sqlvet
        mv sqlvet ./bin/sqlvet

        echo "sqlvet version: "$(./bin/sqlvet --version)
        ./bin/sqlvet .
        echo "FINISHED sqlvet check"
    else
        echo "sqlvet is not supported on windows"
    fi
fi

run_xmlencoderclose=true
if [[ "$DISABLE_XMLENCODERCLOSE" != "" ]]; then
    run_xmlencoderclose=false
fi
if [[ "$SKIP_LINTERS" != "" ]]; then
    run_xmlencoderclose=false
fi
if [[ "$run_xmlencoderclose" == "true" ]]; then
    echo "STARTING xmlencoderclose check"

    # Install xmlencoderclose
    go install github.com/adamdecaf/xmlencoderclose@latest

    # Find the linter
    bin=""
    if which -s xmlencoderclose > /dev/null;
    then
        bin=$(which xmlencoderclose 2>&1 | head -n1)
    fi
    # Public Github runners path
    actions_path="/home/runner/go/bin/xmlencoderclose"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi
    # Moov hosted runner paths
    actions_path="/home/actions/bin/xmlencoderclose"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi

    # Run xmlencoderclose
    if [[ "$bin" != "" ]];
    then
        "$bin" -test ./...
        echo "FINISHED xmlencoderclose check"
    else
        echo "Can't find xmlencoderclose..."
    fi
fi

if [[ "$EXPERIMENTAL" == *"nilaway"* ]];
then
    # nilaway can deliver false positives so it's not currently allowed inside of golangci-lint,
    # however this linter is useful so we offer it.
    #
    # https://github.com/golangci/golangci-lint/issues/4045
    echo "STARTING nilaway check"

    # Install nilaway
    go install go.uber.org/nilaway/cmd/nilaway@latest

    # Find nilaway on PATH
    bin=""
    if which -s nilaway > /dev/null;
    then
        bin=$(which nilaway 2>&1 | head -n1)
    fi
    # Public Github runners path
    actions_path="/home/runner/go/bin/nilaway"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi
    # Moov hosted runner paths
    actions_path="/home/actions/bin/nilaway"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi

    # Run nilaway
    if [[ "$bin" != "" ]];
    then
        "$bin" -test=false ./...
        echo "FINISHED nilaway check"
    fi
fi

# golangci-lint
if [[ "$org" == "moov-io" ]];
then
    STRICT_GOLANGCI_LINTERS=${STRICT_GOLANGCI_LINTERS:="yes"}
fi
if [[ "$SKIP_LINTERS" != "" ]]; then
    disable_golangci=true
fi
if [[ "$OS_NAME" != "windows" ]]; then
    if [[ "$disable_golangci" != "" ]];
    then
        echo "SKIPPING golangci-lint"
    else
        echo "STARTING golangci-lint checks"

        # Download golangci-lint
        wget -q -O - -q https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s "$golangci_version"

        ./bin/golangci-lint version

        # Create a temporary filepath for the config file
        configFilepath=$(mktemp -d)"/config.yml"
        cat <<EOF > "$configFilepath"
run:
  timeout: 5m
  tests: false
  go: "$GO_VERSION"
  skip-dirs:
    - "cmd/*"
    - "admin"
    - "client"
EOF
        # Allow skipping one directory from checks
        if [[ "$GOLANGCI_SKIP_DIR" != "" ]];
        then
            echo "    - ""$GOLANGCI_SKIP_DIR"  >> "$configFilepath"
        fi

        cat <<EOF >> "$configFilepath"
linters:
  disable-all: true
  enable:
    - forbidigo

linters-settings:
  forbidigo:
    forbid:
      - '^panic$'
      - '^time.Sleep$'
EOF
        # Add some specific overrides
        if [[ "$GOLANGCI_ALLOW_PRINT" != "yes" ]];
        then
            echo "      - ^fmt\.Print.*$" >> "$configFilepath"
        fi

        # Run golangci-lint over non-test code first with forbidigo
        ./bin/golangci-lint $GOLANGCI_FLAGS run --config="$configFilepath" --verbose $GOLANGCI_TAGS

        echo "======"

        # Setup golangci-lint to run over the entire codebase
        enabled="-E=asciicheck,bidichk,bodyclose,durationcheck,exhaustive,exportloopref,forcetypeassert,gosec,misspell,nolintlint,rowserrcheck,sqlclosecheck,unused,wastedassign"
        if [ -n "$GOLANGCI_LINTERS" ];
        then
            enabled="$enabled"",$GOLANGCI_LINTERS"
        fi
        if [ -n "$SET_GOLANGCI_LINTERS" ];
        then
            enabled="-E=""$SET_GOLANGCI_LINTERS"
        fi

        # Additional linters for moov-io code
        if [[ "$STRICT_GOLANGCI_LINTERS" == "yes" ]];
        then
            enabled="$enabled"",dupword,gocheckcompilerdirectives,mirror,tenv"
        fi

        disabled="-D=depguard,errcheck,forbidigo"
        if [[ "$DISABLED_GOLANGCI_LINTERS" != "" ]];
        then
            disabled="-D=$DISABLED_GOLANGCI_LINTERS"
        fi

        ./bin/golangci-lint $GOLANGCI_FLAGS run "$enabled" "$disabled" --verbose --go="$GO_VERSION" --skip-dirs="(admin|client)" --timeout=5m $GOLANGCI_TAGS
        echo "FINISHED golangci-lint checks"

        # Cleanup
        rm -f configFilepath
    fi
fi

if [[ "$SKIP_TESTS" == "yes" ]];
then
    echo "SKIPPING Go tests from env var"
    exit 0;
fi

if [[ "$VENDOR_FOR_TESTS" == "yes" ]];
then
    echo "Vendoring deps before running tests"
    go mod tidy
    go mod vendor
fi

## Clear GOARCH and GOOS for testing...
GOARCH=''
GOOS=''

gotest_packages="./..."
if [ -n "$GOTEST_PKGS" ];
then
    gotest_packages="$GOTEST_PKGS"
fi

coveredStatements=0
maximumCoverage=0
coveragePath=$(mktemp -d)"/coverage.txt"

# Run 'go test'
if [[ "$OS_NAME" == "windows" ]]; then
    # Just run short tests on Windows as we don't have Docker support in tests worked out for the database tests
    go test $GOTAGS "$gotest_packages" "$GORACE" -short -coverprofile="$coveragePath" -covermode=atomic $GOTEST_FLAGS
fi
# Add some default flags to every 'go test' case
if [[ "$GOTEST_FLAGS" == "" ]]; then
    # Enable test shuffling
    if [[ "$EXPERIMENTAL" == *"shuffle"* ]]; then
        GOTEST_FLAGS='-shuffle=on'
    fi
fi
if [[ "$OS_NAME" != "windows" ]]; then
    if [[ "$COVER_THRESHOLD" == "disabled" ]]; then
        go test $GOTAGS "$gotest_packages" "$GORACE" -count 1 $GOTEST_FLAGS
    else
        # Optionally profile each package
        if [[ "$PROFILE_GOTEST" == "yes" ]]; then
            for pkg in "${GOPKGS[@]}"
            do
                # fixup the sub-package for writing cpu/mem profile
                dir=${pkg#$MODNAME"/"}
                if [[ "$pkg" == "$dir" ]];
                then
                    dir="."
                fi

                go test $GOTAGS "$pkg" "$GORACE" \
                   -covermode=atomic \
                   -coverprofile="$dir"/coverage.txt \
                   -test.cpuprofile="$dir"/cpu.out \
                   -test.memprofile="$dir"/mem.out \
                   -count 1 $GOTEST_FLAGS

                coverage=$(go tool cover -func="$dir"/coverage.txt | grep total | grep -Eo '[0-9]+\.[0-9]+')
                if [[ "$coverage" > "0.0" ]];
                then
                    coveredStatements=$(echo "$coveredStatements" + "$coverage" | bc)
                    maximumCoverage=$((maximumCoverage+100))
                fi
            done
        else
            # Otherwise just run Go tests without profiling
            go test $GOTAGS "$gotest_packages" "$GORACE" -coverprofile="$coveragePath" -covermode=atomic -count 1 $GOTEST_FLAGS
        fi
    fi
fi

# Verify Code Coverage Threshold
if [[ "$COVER_THRESHOLD" != "" ]]; then
    if [[ -f "$coveragePath" && "$PROFILE_GOTEST" != "yes" ]];
    then
        # Ignore test directories in coverage analysis
        cat "$coveragePath" | grep -v -E "/client/" | grep -v -E "/pkg*/*test" | grep -v -E "/internal*/*test" | grep -v -E "/examples/" | grep -v -E "/gen/"  > coverage.txt
        coveredStatements=$(go tool cover -func=coverage.txt | grep -E '^total:' | grep -Eo '[0-9]+\.[0-9]+')
        maximumCoverage=100
    fi

    avgCoverage=$(printf "%.1f" $(echo "($coveredStatements / $maximumCoverage)*100" | bc -l))
    echo "Project has $avgCoverage% statement coverage."

    if [[ "$avgCoverage" < "$COVER_THRESHOLD" ]]; then
        echo "ERROR: statement coverage is not sufficient, $COVER_THRESHOLD% is required"
        exit 1
    else
        echo "SUCCESS: project has sufficient statement coverage (over $COVER_THRESHOLD%)"
    fi
else
    echo "Skipping code coverage threshold, consider setting COVER_THRESHOLD. (Example: 85.0)"
fi

echo "finished running Go tests"
