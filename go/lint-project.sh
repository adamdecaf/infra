#!/bin/bash
set -e

mkdir -p ./bin/

# Collect all our files for processing
GOFILES=($(find . -type f -name '*.go' | grep -v client | grep -v vendor))

# Set OS_NAME if it's empty (local dev)
OS_NAME=$TRAVIS_OS_NAME
if [[ "$OS_NAME" == "" ]]; then
    if [[ $(uname -s) == "Darwin" ]]; then
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
fi

# Misspell
if [[ "$OS_NAME" == "linux" ]]; then wget -q -O misspell.tar.gz https://github.com/client9/misspell/releases/download/v0.3.4/misspell_0.3.4_linux_64bit.tar.gz; fi
if [[ "$OS_NAME" == "osx" ]]; then wget -q -O misspell.tar.gz https://github.com/client9/misspell/releases/download/v0.3.4/misspell_0.3.4_mac_64bit.tar.gz; fi
if [[ "$OS_NAME" != "windows" ]]; then
    tar xf misspell.tar.gz
    cp ./misspell ./bin/misspell

    ignore=""
    if [ -n "$MISSPELL_IGNORE" ];
    then
        ignore=$MISSPELL_IGNORE
    fi

    for file in "${GOFILES[@]}"
    do
        ./bin/misspell -error -locale US -i "$ignore" $file
    done
fi

# gitleaks
# Right now there are some false positives which make it harder to scan
# See: https://github.com/zricethezav/gitleaks/issues/394
if [[ "$EXPERIMENTAL" == *"gitleaks"* ]]; then
    if [[ "$OS_NAME" == "linux" ]]; then wget -q -O ./bin/gitleaks https://github.com/zricethezav/gitleaks/releases/download/v6.1.2/gitleaks-linux-amd64; fi
    if [[ "$OS_NAME" == "osx" ]]; then wget -q -O ./bin/gitleaks https://github.com/zricethezav/gitleaks/releases/download/v6.1.2/gitleaks-darwin-amd64; fi

    if [[ "$OS_NAME" != "windows" ]]; then
        chmod +x ./bin/gitleaks

        # Scan a few of the most recent commits
        depth=10
        if [ -n "$GITLEAKS_DEPTH" ]; then
            depth=$GITLEAKS_DEPTH
        fi
        ./bin/gitleaks --depth=$depth --repo-path=$(pwd) --pretty --verbose
    fi
fi

# staticcheck
if [[ "$OS_NAME" == "linux" ]]; then wget -q -O staticcheck.tar.gz https://github.com/dominikh/go-tools/releases/download/2020.1.5/staticcheck_linux_amd64.tar.gz; fi
if [[ "$OS_NAME" == "osx" ]]; then wget -q -O staticcheck.tar.gz https://github.com/dominikh/go-tools/releases/download/2020.1.5/staticcheck_darwin_amd64.tar.gz; fi
if [[ "$OS_NAME" != "windows" ]]; then
    tar xf staticcheck.tar.gz
    cp ./staticcheck/staticcheck ./bin/staticcheck

    # Grab directories with Go files but not 'admin' or 'client'
    GODIRS=$(find ./** -mindepth 1 -type f -name "*.go" | grep -v admin | grep -v client | xargs -n1 -I '{}' dirname {} | sort -u)
    ./bin/staticcheck $GODIRS
fi

# nancy (vulnerable dependencies)
if [[ "$OS_NAME" == "linux" ]]; then wget -q -O ./bin/nancy https://github.com/sonatype-nexus-community/nancy/releases/download/v1.0.0/nancy-linux.amd64-v1.0.0; fi
if [[ "$OS_NAME" == "osx" ]]; then wget -q -O ./bin/nancy https://github.com/sonatype-nexus-community/nancy/releases/download/v1.0.0/nancy-darwin.amd64-v1.0.0; fi
if [[ "$OS_NAME" != "windows" ]]; then
    chmod +x ./bin/nancy

    ignored_deps=(
        # Consul Enterprise
        CVE-2018-19653
        CVE-2020-13250
        CVE-2020-7219
        # Vault Enterprise
        CVE-2020-10660
        CVE-2020-10661
        CVE-2020-13223
        CVE-2020-7220
        # etcd
        CVE-2020-15114
        CVE-2020-15115
        CVE-2020-15136
    )
    ignored=$(printf ",%s" "${ignored_deps[@]}")
    ignored=${ignored:1}

    # Append additional CVEs
    if [ -n "$IGNORED_CVES" ];
    then
        ignored="$ignored"",""$IGNORED_CVES"
    fi

    # Ignore Consul and Vault Enterprise, they need a gocloud.dev release
    go list -m all | ./bin/nancy sleuth --exclude-vulnerability "$ignored"

    echo "" # newline
fi

# golangci-lint
if [[ "$OS_NAME" != "windows" ]]; then
    wget -q -O - -q https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | sh -s v1.31.0
    ./bin/golangci-lint run --skip-dirs="(admin|client)" --timeout=2m --disable=errcheck
fi

# gocyclo
if [[ "$OS_NAME" == "linux" ]]; then wget -q -O ./bin/gocyclo https://github.com/adamdecaf/gocyclo/releases/download/2019-08-09/gocyclo-linux-amd64; fi
if [[ "$OS_NAME" == "osx" ]]; then wget -q -O ./bin/gocyclo https://github.com/adamdecaf/gocyclo/releases/download/2019-08-09/gocyclo-darwin-amd64; fi
if [[ "$OS_NAME" != "windows" ]]; then
    chmod +x ./bin/gocyclo

    args='-over 25'
    if [ -n "$GOCYCLO_LIMIT" ]; then
        args="-over $GOCYCLO_LIMIT"
    fi
    for file in "${GOFILES[@]}"
    do
        ./bin/gocyclo $args $file
    done
fi

# Run exhaustive to verify Enums aren't missing cases
if [[ "$EXPERIMENTAL" == *"exhaustive"* ]]; then
    go get github.com/nishanths/exhaustive/cmd/exhaustive
    echo "Running nishanths/exhaustive"

    if [ -n "$DEFAULT_SIGNIFIES_EXHAUSTIVE" ]; then
        exhaustive -default-signifies-exhaustive ./...
    else
        exhaustive ./...
    fi
fi

## Clear GOARCH and GOOS for testing...
GOARCH=''
GOOS=''

# Run 'go test'
if [[ "$OS_NAME" == "windows" ]]; then
    # Just run short tests on Windows as we don't have Docker support in tests worked out for the database tests
    go test ./... -race -short -coverprofile=coverage.txt -covermode=atomic
fi
if [[ "$OS_NAME" != "windows" ]]; then
    go test ./... -race -coverprofile=coverage.txt -covermode=atomic
fi
