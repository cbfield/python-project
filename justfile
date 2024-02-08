#!/usr/bin/env just --justfile

# TODO
# test
# lint
# deploy

# Variables

name := "flask-app"
image := "cbfield/flask-app:latest"
port := "5001"
log_level := "DEBUG"
gh_token := `cat ~/.secret/gh_token`

aws_codeartifact_domain := ""
aws_codeartifact_domain_owner := ""
aws_codeartifact_repository := ""

# Recipes

# Show help and status info
@default:
    just --list
    printf "\nStatus:\n"
    just status

# Shortcut for testing APIs running on localhost
api PATH="/api/v1/":
    curl \
        --connect-timeout 5 \
        --max-time 10 \
        --retry 3 \
        --retry-delay 1 \
        --retry-max-time 30 \
        --retry-connrefused \
        --no-progress-meter \
        http://localhost:{{port}}{{PATH}}

# Log into AWS SSO and begin a session with AWS CodeArtifact
aws-login: _requires-aws
    #!/usr/bin/env -S bash -euxo pipefail
    if [[ -z $(aws sts get-caller-identity 2>/dev/null) ]]; then
        aws sso login;
    fi
    if [[ -z "{{aws_codeartifact_domain}}" ]] && [[ -z "{{aws_codeartifact_repository}}" ]]; then
        exit
    fi
    repo_flags="--domain {{aws_codeartifact_domain}} --domain-owner {{aws_codeartifact_domain_owner}} --repository {{aws_codeartifact_repository}}"
    if command -v pip >/dev/null; then
        aws codeartifact login --tool pip $repo_flags
    fi
    if command -v npm >/dev/null; then
        aws codeartifact login --tool npm $repo_flags
    fi

# Build the app container with Docker
build: start-docker
    docker build -t {{image}} .

# Generate requirements*.txt from requirements*.in using pip-tools
build-reqs *FLAGS:
    just build-reqs-dev {{FLAGS}}
    just build-reqs-test {{FLAGS}}
    just build-reqs-deploy {{FLAGS}}

# Generate requirements.txt from requirements.in using pip-tools
build-reqs-deploy *FLAGS:
    pip-compile {{FLAGS}} --strip-extras -o requirements.txt requirements.in

# Generate requirements-dev.txt from requirements-dev.in using pip-tools
build-reqs-dev *FLAGS:
    pip-compile {{FLAGS}} --strip-extras -o requirements-dev.txt requirements-dev.in

# Generate requirements-test.txt from requirements-test.in using pip-tools
build-reqs-test *FLAGS:
    pip-compile {{FLAGS}} --strip-extras -o requirements-test.txt requirements-test.in

# Remove development containers and images
clean: stop clean-containers clean-images

# Remove all containers and images
clean-all: stop-all-containers clean-all-containers clean-all-images

# Remove all containers
clean-all-containers:
    #!/usr/bin/env -S bash -euxo pipefail
    containers=$(docker ps -aq)
    echo -n "$containers" | grep -q . && docker rm -vf "$containers" || :

# Remove all images
clean-all-images:
    docker image prune --all --force

# Remove containers by ID
clean-containers CONTAINERS="$(just get-dev-containers)":
    #!/usr/bin/env -S bash -euxo pipefail
    exited=$(docker ps -q -f "status=exited")
    echo -n "$exited" | grep -q . && docker rm -vf "$exited" || :
    containers="{{CONTAINERS}}"
    echo -n "$containers" | grep -q . && docker rm -vf "$containers" || :

# Remove images by ID
clean-images IMAGES="$(just get-dev-images)":
    #!/usr/bin/env -S bash -euxo pipefail
    dangling=$(docker images -f "dangling=true" -q)
    echo -n "$dangling" | grep -q . && docker rmi -f "$dangling" || :
    images="{{IMAGES}}"
    if echo -n "$images" | grep -q . ; then 
        for image in $images; do
            if [[ -z $(just _is-image-used "$image") ]]; then
                docker rmi -f "$image"
            fi
        done
    fi

# Pretty-print Docker status information
docker-status:
    #!/usr/bin/env -S bash -euo pipefail
    containers=$(docker ps -a)
    images=$(docker images)
    printf "\nContainers:\n\n%s\n\nImages:\n\n%s\n\n" "$containers" "$images"

# List development container IDs
@get-dev-containers:
    echo $(docker ps -q --filter name="{{name}}*")

# List development image IDs
@get-dev-images:
    echo $(docker images -q)

# (JSON util) Return the first item in a JSON list. Return nothing if invalid JSON or type != list.
_get-first-item:
    #!/usr/bin/env -S python3
    import json, sys
    try:
        d = json.load(sys.stdin)
    except json.decoder.JSONDecodeError:
        sys.exit()
    if type(d) is list: 
        print(json.dumps(d[0]))

# (Github API util) Return the id of a given asset in a Github release
_get-gh-release-asset-id ASSET:
    #!/usr/bin/env -S python3
    import json, sys
    try:
        d = json.load(sys.stdin)
    except json.decoder.JSONDecodeError:
        sys.exit()
    print(next((a["id"] for a in d["assets"] if a["name"]=="{{ASSET}}"),""),end="")

# Get a Github release (json)
get-gh-release OWNER REPO TAG:
    #!/usr/bin/env -S bash -euo pipefail
    headers='-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer {{gh_token}}"'
    curl "$headers" -L --no-progress-meter https://api.github.com/repos/{{OWNER}}/{{REPO}}/releases/tags/{{TAG}} | just _handle-gh-api-errors

# Download a Github release binary asset
get-gh-release-binary OWNER REPO TAG ASSET DEST:
    #!/usr/bin/env -S bash -euo pipefail
    printf "\nRetrieving Release Binary...\n\nOWNER:\t\t%s\nREPO:\t\t%s\nRELEASE TAG:\t%s\nTARGET:\t\t%s\nDESTINATION:\t%s\n\n" {{OWNER}} {{REPO}} {{TAG}} {{ASSET}} {{DEST}}
    asset_id=$(just get-gh-release {{OWNER}} {{REPO}} {{TAG}} | just _get-gh-release-asset-id {{ASSET}})
    if [[ -z "$asset_id" ]]; then
        printf "Asset %s not found.\n\n" "{{ASSET}}" >&2; exit 1
    fi
    curl -L --no-progress-meter -o "{{DEST}}" \
      -H "Accept: application/octet-stream" -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer {{gh_token}}" \
      https://api.github.com/repos/{{OWNER}}/{{REPO}}/releases/assets/$asset_id
    chmod +x "{{DEST}}"

# Get the latest release for a given Github repo
get-latest-gh-release OWNER REPO:
    #!/usr/bin/env -S bash -euo pipefail
    headers='-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer {{gh_token}}"'
    releases=$(curl "$headers" -L --no-progress-meter https://api.github.com/repos/{{OWNER}}/{{REPO}}/releases)
    echo $releases | just _handle-gh-api-errors | just _get-first-item

# (Github API util) Return unchanged JSON input if valid JSON and doesn't contain not-found or rate-limit-exceeded errors.
_handle-gh-api-errors:
    #!/usr/bin/env -S python3
    import json, sys
    try:
        d = json.load(sys.stdin)
    except json.decoder.JSONDecodeError:
        sys.exit()
    if 'message' in d and (d['message']=='Not Found' or d['message'].startswith('API rate limit exceeded')):
        sys.exit()
    print(json.dumps(d))

# Install the latest version of the AWS CLI
install-aws:
    #!/usr/bin/env -S bash -euo pipefail
    echo "Installing the AWS Command Line Interface..."
    case "{{os()}}" in
        linux)
            curl --no-progress-meter "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
            trap 'rm -rf -- "awscliv2.zip"' EXIT
            unzip awscliv2.zip
            sudo ./aws/install
            trap 'rm -rf -- "./aws"' EXIT
        ;;
        macos)
            curl --no-progress-meter "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
            trap 'rm -rf -- "AWSCLIV2.pkg"' EXIT
            sudo installer -pkg AWSCLIV2.pkg -target /
        ;;
        windows)
            msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
        ;;
        *)
            echo "Unable to determine proper install method. Cancelling" >&2; exit 1
        ;;
    esac

# Install jq via pre-built binary from the Github API
install-jq VERSION="latest" INSTALL_DIR="$HOME/bin" TARGET="":
    #!/usr/bin/env -S bash -euo pipefail
    version="{{VERSION}}"
    if [[ "$version" == "latest" ]]; then
        echo "Looking up latest version..."
        release=$(just get-latest-gh-release jqlang jq)
        version=$(echo "$release" | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"].split("-")[-1])')
        printf "Found %s\n" "$version."
    else
        printf "Validating version %s...\n" "$version"
        release=$(just get-gh-release jqlang jq "jq-$version")
        if [[ -n "$release" ]]; then
            echo "Valid!"
        else
            printf "Version %s not found.\n\n" "$version" >&2; exit 1
        fi
    fi
    case $(uname -m)-$(uname -s | cut -d- -f1) in
        arm64-Darwin)       asset=jq-macos-arm64;;
        x86_64-Darwin)      asset=jq-macos-amd64;;
        x86_64-Linux)       asset=jq-linux-amd64;;
        x86_64-MINGW64_NT)  asset=jq-windows-amd64;;
        x86_64-Windows_NT)  asset=jq-windows-amd64;;
    esac
    if [[ -n "{{TARGET}}" ]]; then
        asset="{{TARGET}}"
    fi
    just get-gh-release-binary jqlang jq "jq-$version" "$asset" "{{INSTALL_DIR}}/jq"
    if command -v jq >/dev/null; then
        if jq --version >/dev/null; then
            printf "\njq installed: %s\n\n" $(jq --version)
        else
            printf "\nInstallation failed!\n\n"
        fi
    else
        printf "\njq installed successfully! But it doesn't appear to be on your \$PATH.\n"
        printf "You can add it to your path by running this:\n\n❯ export PATH={{INSTALL_DIR}}:\$PATH\n\n"
    fi

# (Docker util) Check if a given image is being used by any containers
_is-image-used IMAGE:
    #!/usr/bin/env -S bash -euo pipefail
    for container in $(docker ps -aq); do
        if docker ps -q --filter "ancestor={{IMAGE}}" | grep -q .; then
            echo -n 0; exit
        fi
    done

# Pretty-print development container information
pretty-dev-containers:
    #!/usr/bin/env -S bash -euo pipefail
    format='{"Name":.Names,"Image":.Image,"Ports":.Ports,"Created":.RunningFor,"Status":.Status}'
    if ! command -v jq >/dev/null; then jq="docker run -i --rm ghcr.io/jqlang/jq"; else jq=jq; fi
    docker ps --filter name="{{name}}*" --format=json 2>/dev/null | eval '$jq "$format"'

# (AWS API util) Exit with feedback if the AWS CLI isn't installed
_requires-aws:
    #!/usr/bin/env -S bash -euo pipefail
    if ! command -v aws >/dev/null; then
        printf "You need the AWS Command Line Interface to run this command.\n\n❯ just install-aws\n\n" >&2
        exit 1
    fi

# Build and run the app
run PORT="" NAME="": build
    #!/usr/bin/env -S bash -euo pipefail
    port="{{PORT}}"
    if [[ -z "$port" ]]; then 
        port="{{port}}"
    fi
    name="{{NAME}}"
    if [[ -z "$name" ]]; then 
        name="flask-app-$(head -c 8 <<< `uuidgen`)"
    fi
    docker run --rm -d --name="$name" -p "$port":5000 -e LOG_LEVEL={{log_level}} {{image}}

# Start the Docker daemon
start-docker:
    #!/usr/bin/env -S bash -euo pipefail
    if ( ! docker stats --no-stream 2>/dev/null ); then
        echo "Starting the Docker daemon..."
        if [[ {{os()}} == "macos" ]]; then
            open /Applications/Docker.app
        else if command -v systemctl >/dev/null; then
            sudo systemctl start docker
        else
            echo "Unable to start the Docker daemon." >&2; exit 1
        fi
        fi
        while ( ! docker stats --no-stream 2>/dev/null ); do
            sleep 1
        done
    fi

# Print information about the current development environment
status:
    #!/usr/bin/env -S bash -euo pipefail
    containers=$(just get-dev-containers 2>/dev/null)
    if [[ -z $containers ]]; then
        printf "\nNo development containers.\n\n";
    else
        printf "\nDevelopment Containers:\n\n"
        just pretty-dev-containers; echo
    fi
    printf "Docker Status:\n\n"
    if ( docker stats --no-stream 2>/dev/null ); then
        just docker-status
    else
        printf "Daemon stopped.\n\n"
    fi

# Stop containers by ID
stop CONTAINERS="$(just get-dev-containers)":
    #!/usr/bin/env -S bash -euxo pipefail
    containers="{{CONTAINERS}}"
    echo -n "$containers" | grep -q . && docker stop "$containers" || :

alias stop-all := stop-all-containers
# Stop all containers
stop-all-containers:
    #!/usr/bin/env -S bash -euxo pipefail
    containers=$(docker ps -aq)
    echo -n "$containers" | grep -q . && docker stop "$containers" || :
