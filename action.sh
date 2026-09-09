#!/usr/bin/env bash

# Copyright 2024-2025 Nils Knieling. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Create a on-demand self-hosted GitHub Actions Runner in Hetzner Cloud
# https://docs.hetzner.cloud/#servers-create-a-server

# Deliberately retain upstream non-errexit/nounset behavior: registration polling
# expects jq misses. New cleanup/API paths check failures explicitly.
set -o pipefail
MY_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
cd "$MY_SCRIPT_DIR" || exit 1

# Function to exit the script with a failure message
function exit_with_failure() {
	echo >&2 "FAILURE: $1"  # Print error message to stderr
	exit 1
}

# Function to check all values of a comma separated list are integers
function check_all_integers() {
	IFS=',' read -ra _values <<< "$1"
	for value in "${_values[@]}"; do
		if [[ ! "$value" =~ ^[0-9]+$ ]]; then
			echo "$value"
			return 1
		fi
	done
	return 0
}

# Define required commands
MY_COMMANDS=(
	base64
	curl
	cut
	envsubst
	jq
)
# Check if required commands are available
for MY_COMMAND in "${MY_COMMANDS[@]}"; do
	if ! command -v "$MY_COMMAND" >/dev/null 2>&1; then
		exit_with_failure "The command '$MY_COMMAND' was not found. Please install it."
	fi
done

# Check if files exist
MY_FILES=(
	"cloud-init.template.yml"
	"create-server.template.json"
	"install.sh"
)
# Check if required commands are available
for MY_FILE in "${MY_FILES[@]}"; do
	if [[ ! -f "$MY_FILE" ]]; then
		exit_with_failure "The file '$MY_FILE' was not found!"
	fi
done

# Retry wait time in secounds
WAIT_SEC=10

#
# INPUT
#

# GitHub Actions inputs
# https://docs.github.com/en/actions/sharing-automations/creating-actions/metadata-syntax-for-github-actions#inputs
# When you specify an input, GitHub creates an environment variable for the input with the name INPUT_<VARIABLE_NAME>.

# Set maximum retries * WAIT_SEC (10 sec) for Hetzner Server creation via the Hetzer Cloud API (default: 360 [1 hour])
# If INPUT_CREATE_WAIT is set, use its value; otherwise, use "360".
MY_CREATE_WAIT=${INPUT_CREATE_WAIT:-360}
if [[ ! "$MY_CREATE_WAIT" =~ ^[0-9]+$ ]]; then
	exit_with_failure "The maximum retries for Hetzner Server creation via the Hetzer Cloud API must be an integer!"
fi

# Set maximum retries * WAIT_SEC (10 sec) for Hetzner Server deletion via the Hetzer Cloud API (default: 360 [1 hour])
# If INPUT_DELETE_WAIT is set, use its value; otherwise, use "360".
MY_DELETE_WAIT=${INPUT_DELETE_WAIT:-360}
if [[ ! "$MY_DELETE_WAIT" =~ ^[0-9]+$ ]]; then
	exit_with_failure "The maximum retries for Hetzner Server deletion via the Hetzer Cloud API must be an integer!"
fi

# Enable IPv4 (default: false)
# If INPUT_ENABLE_IPV4 is set, use its value; otherwise, use "false".
MY_ENABLE_IPV4=${INPUT_ENABLE_IPV4:-"true"}
if [[ "$MY_ENABLE_IPV4" != "true" && "$MY_ENABLE_IPV4" != "false" ]]; then
	exit_with_failure "Enable IPv4 must be 'true' or 'false'."
fi

# Enable IPv6 (default: true)
# If INPUT_ENABLE_IPV6 is set, use its value; otherwise, use "true".
MY_ENABLE_IPV6=${INPUT_ENABLE_IPV6:-"true"}
if [[ "$MY_ENABLE_IPV6" != "true" && "$MY_ENABLE_IPV6" != "false" ]]; then
	exit_with_failure "Enable IPv6 must be 'true' or 'false'."
fi

# Set the GitHub Personal Access Token (PAT).
# Retrieves the value from the INPUT_GITHUB_TOKEN environment variable.
MY_GITHUB_TOKEN=${INPUT_GITHUB_TOKEN}
if [[ -z "$MY_GITHUB_TOKEN" ]]; then
	exit_with_failure "GitHub Personal Access Token (PAT) token is required!"
fi

# Set the GitHub repository name.
# This retrieves the value from the GITHUB_ACTION_REPOSITORY environment variable,
# which is automatically set in GitHub Actions workflows.
# https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/store-information-in-variables#default-environment-variables
MY_GITHUB_REPOSITORY=${GITHUB_REPOSITORY}
if [[ -z "$MY_GITHUB_REPOSITORY" ]]; then
	exit_with_failure "GitHub repository is required!"
fi
# Set the repository owner's account ID (used for Hetzner Cloud Server label).
MY_GITHUB_REPOSITORY_OWNER_ID=${GITHUB_REPOSITORY_OWNER_ID:-"0"}
# Set The ID of the repository (used for Hetzner Cloud Server label).
MY_GITHUB_REPOSITORY_ID=${GITHUB_REPOSITORY_ID:-"0"}

# Set the Hetzner Cloud API token.
# Retrieves the value from the INPUT_HCLOUD_TOKEN environment variable.
MY_HETZNER_TOKEN=${INPUT_HCLOUD_TOKEN}
if [[ -z "$MY_HETZNER_TOKEN" ]]; then
	exit_with_failure "Hetzner Cloud API token is not set."
fi

# Set the image to use for the instance (default: ubuntu-24.04)
# If INPUT_IMAGE is set, use its value; otherwise, use "ubuntu-24.04".
MY_IMAGE=${INPUT_IMAGE:-"ubuntu-24.04"}
# Check allowed characters
if [[ ! "$MY_IMAGE" =~ ^[a-zA-Z0-9\._-]{1,63}$ ]]; then
	exit_with_failure "'$MY_IMAGE' is not a valid OS image name!"
fi

# Set the location/region for the instance (default: nbg1)
# If INPUT_LOCATION is set, use its value; otherwise, use "nbg1".
MY_LOCATION=${INPUT_LOCATION:-"nbg1"}

# Specify here which mode you want to use (default: create):
# - create : Create a new runner
# - delete : Delete the previously created runner
# If INPUT_MODE is set, use its value; otherwise, use "create".
MY_MODE=${INPUT_MODE:-"create"}
if [[ "$MY_MODE" != "create" && "$MY_MODE" != "delete" ]]; then
	exit_with_failure "Mode must be 'create' or 'delete'."
fi

# Set the name of the instance (default: gh-runner-$RANDOM)
# If INPUT_NAME is set, use its value; otherwise, generate a random name using "gh-runner-$RANDOM".
MY_NAME=${INPUT_NAME:-"gh-runner-$RANDOM"}
# Check allowed characters
if [[ ! "$MY_NAME" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
	exit_with_failure "'$MY_NAME' is not a valid hostname or label!"
fi
if [[ "$MY_NAME" == "hetzner" ]]; then
	exit_with_failure "'hetzner' is not allowed as hostname!"
fi

# Set the network for the instance (default: null)
# If INPUT_NETWORKS is set, use its value; otherwise, use "null".
MY_NETWORKS=${INPUT_NETWORKS:-"null"}
if [[ "$MY_NETWORKS" != "null" ]]; then
	invalid_value=$(check_all_integers "$MY_NETWORKS") || {
		exit_with_failure "Invalid network ID: $invalid_value (must be 'null' or an integer)"
	}
fi

# Optional firewall IDs and exact private IPv4 (one network only).
MY_FIREWALLS=${INPUT_FIREWALLS:-null}
if [[ "$MY_FIREWALLS" != "null" && ! "$MY_FIREWALLS" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; then
	exit_with_failure "Firewall IDs must be comma-separated positive integers."
fi
MY_PRIVATE_IPV4=${INPUT_PRIVATE_IPV4:-}
if [[ -n "$MY_PRIVATE_IPV4" ]]; then
	[[ "$MY_NETWORKS" =~ ^[1-9][0-9]*$ ]] || exit_with_failure "private_ipv4 requires exactly one positive network ID."
	jq -en --arg ip "$MY_PRIVATE_IPV4" '$ip | split(".") | length == 4 and all(.[];
		test("^(0|[1-9][0-9]{0,2})$") and (tonumber <= 255))' >/dev/null \
		|| exit_with_failure "private_ipv4 must be canonical dotted IPv4."
fi

# Set bash commands to run before the runner starts.
# If INPUT_PRE_RUNNER_SCRIPT is set, use its value; otherwise, use "".
MY_PRE_RUNNER_SCRIPT=${INPUT_PRE_RUNNER_SCRIPT:-""}

# Set the primary IPv4 address for the instance (default: null)
# If INPUT_PRIMARY_IPV4 is set, use its value; otherwise, use "null".
MY_PRIMARY_IPV4=${INPUT_PRIMARY_IPV4:-"null"}
# Check if MY_PRIMARY_IPV4 is an integer
if [[ "$MY_PRIMARY_IPV4" != "null" && ! "$MY_PRIMARY_IPV4" =~ ^[0-9]+$ ]]; then
	exit_with_failure "The primary IPv4 ID must be 'null' or an integer!"
fi

# Set the primary IPv6 address for the instance (default: null)
# If INPUT_PRIMARY_IPV6 is set, use its value; otherwise, use "null".
MY_PRIMARY_IPV6=${INPUT_PRIMARY_IPV6:-"null"}
# Check if MY_PRIMARY_IPV6 is an integer
if [[ "$MY_PRIMARY_IPV6" != "null" && ! "$MY_PRIMARY_IPV6" =~ ^[0-9]+$ ]]; then
	exit_with_failure "The primary IPv6 ID must be 'null' or an integer!"
fi

# Set default GitHub Actions Runner installation directory (default: /actions-runner)
# If INPUT_RUNNER_DIR is set, its value is used. Otherwise, the default value "/actions-runner" is used.
MY_RUNNER_DIR=${INPUT_RUNNER_DIR:-"/actions-runner"}
# Check allowed characters
if [[ ! "$MY_RUNNER_DIR" =~ ^/([^/]+/)*[^/]+$ ]]; then
	exit_with_failure "'$MY_RUNNER_DIR' is not a valid absolute directory path without a trailing slash!"
fi

# Set default GitHub Actions Runner version (default: latest)
# If INPUT_RUNNER_VERSION is set, its value is used. Otherwise, the default value "latest" is used.
# Releases: https://github.com/actions/runner/releases
MY_RUNNER_VERSION=${INPUT_RUNNER_VERSION:-"latest"}
# Check allowed values
if [[ "$MY_RUNNER_VERSION" != "latest" && "$MY_RUNNER_VERSION" != "skip" && ! "$MY_RUNNER_VERSION" =~ ^[0-9\.]{1,63}$ ]]; then
	exit_with_failure "'$MY_RUNNER_VERSION' is not a valid GitHub Actions Runner version! Enter 'latest', 'skip' or the version without 'v'."
fi

# Set maximal retries * WAIT_SEC (10 sec) for GitHub Actions Runner registration (default: 60 [10 min])
# If INPUT_RUNNER_WAIT is set, use its value; otherwise, use "60".
MY_RUNNER_WAIT=${INPUT_RUNNER_WAIT:-"60"}
# Check if MY_RUNNER_WAIT is an integer
if [[ ! "$MY_RUNNER_WAIT" =~ ^[0-9]+$ ]]; then
	exit_with_failure "The maximum wait time (retries) for GitHub Action Runner registration must be an integer!"
fi

# Set Hetzner Cloud Server ID
# Check only if mode is delete.
MY_HETZNER_SERVER_ID=${INPUT_SERVER_ID}

# Set the server type/instance type (default: cx23)
# If INPUT_SERVER_TYPE is set, use its value; otherwise, use "cx23".
MY_SERVER_TYPE=${INPUT_SERVER_TYPE:-"cx23"}

# Set maximal retries * WAIT_SEC (10 sec) for Hetzner Cloud Server (default: 30 [5 min])
# If INPUT_SERVER_WAIT is set, use its value; otherwise, use "30".
MY_SERVER_WAIT=${INPUT_SERVER_WAIT:-"30"}
# Check if MY_RUNNER_WAIT is an integer
if [[ ! "$MY_SERVER_WAIT" =~ ^[0-9]+$ ]]; then
	exit_with_failure "The maximum wait time (reties) for a running Hetzner Cloud Server must be an integer!"
fi

# Set the SSH key to use for the instance (default: null)
# If INPUT_SSH_KEYS is set, use its value; otherwise, use "null".
MY_SSH_KEYS=${INPUT_SSH_KEYS:-"null"}
if [[ "$MY_SSH_KEYS" != "null" ]]; then
	invalid_value=$(check_all_integers "$MY_SSH_KEYS") || {
		exit_with_failure "Invalid SSH key ID: $invalid_value (must be 'null' or an integer)"
	}
fi

# Set the volume ID which should be attached to the instance at the creation time (default: null)
# If INPUT_VOLUMES is set, use its value; otherwise, use "null".
MY_VOLUMES=${INPUT_VOLUMES:-"null"}
if [[ "$MY_VOLUMES" != "null" ]]; then
	invalid_value=$(check_all_integers "$MY_VOLUMES") || {
		exit_with_failure "Invalid volume ID: $invalid_value (must be 'null' or an integer)"
	}
fi

#
# DELETE
#

# Capture status separately: transport errors and unrecognized HTTP responses fail closed.
function cleanup_request() {
	MY_HTTP_BODY=$(curl -sS --connect-timeout 10 --max-time 30 --retry-max-time 60 -w '\n%{http_code}' "$@") || return 1
	MY_HTTP_STATUS=${MY_HTTP_BODY##*$'\n'}
	MY_HTTP_BODY=${MY_HTTP_BODY%$'\n'*}
}

function delete_server() {
	cleanup_request -X DELETE --retry "$MY_DELETE_WAIT" --retry-delay "$WAIT_SEC" \
		-H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
		"https://api.hetzner.cloud/v1/servers/$MY_HETZNER_SERVER_ID" || return 1
	case "$MY_HTTP_STATUS" in
	200) jq -e '.action.id | numbers | select(. > 0)' <<< "$MY_HTTP_BODY" >/dev/null || return 1
		echo "Hetzner Cloud Server deletion accepted." ;;
	404) jq -e '.error.code == "not_found"' <<< "$MY_HTTP_BODY" >/dev/null || return 1
		echo "Hetzner Cloud Server already absent." ;;
	*) return 1 ;;
	esac
}

function delete_registration() {
	local MY_PAGE MY_COUNT MY_MATCHES MY_IDS="" MY_TOTAL="" MY_SEEN=0 MY_PAGE_TOTAL
	local MY_DEADLINE=$((SECONDS + 300))
	# Bound discovery; never delete from a partial or malformed inventory.
	for ((MY_PAGE=1; MY_PAGE<=1000; MY_PAGE++)); do
		((SECONDS < MY_DEADLINE)) || return 1
		cleanup_request -H "Accept: application/vnd.github+json" \
			-H "Authorization: Bearer ${MY_GITHUB_TOKEN}" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"https://api.github.com/repos/${MY_GITHUB_REPOSITORY}/actions/runners?per_page=100&page=$MY_PAGE" || return 1
		[[ "$MY_HTTP_STATUS" == "200" ]] || return 1
		jq -e '(.total_count | type == "number" and . >= 0 and floor == .) and
			(.runners | type == "array") and all(.runners[];
			(.name | type == "string") and (.id | type == "number" and . > 0 and floor == .))' \
			<<< "$MY_HTTP_BODY" >/dev/null || return 1
		MY_PAGE_TOTAL=$(jq -r '.total_count' <<< "$MY_HTTP_BODY")
		[[ -z "$MY_TOTAL" || "$MY_TOTAL" == "$MY_PAGE_TOTAL" ]] || return 1
		MY_TOTAL=$MY_PAGE_TOTAL
		MY_COUNT=$(jq '.runners | length' <<< "$MY_HTTP_BODY")
		MY_MATCHES=$(jq -r --arg name "$MY_NAME" '.runners[] | select(.name == $name) | .id' <<< "$MY_HTTP_BODY")
		if [[ -n "$MY_MATCHES" ]]; then MY_IDS+="${MY_MATCHES}"$'\n'; fi
		MY_SEEN=$((MY_SEEN + MY_COUNT))
		if ((MY_COUNT < 100)); then break; fi
	done
	((MY_PAGE <= 1000 && MY_SEEN == MY_TOTAL)) || return 1
	if [[ -z "$MY_IDS" ]]; then
		echo "GitHub Actions Runner already absent."
		return 0
	fi
	MY_GITHUB_RUNNER_ID=${MY_IDS%$'\n'}
	[[ "$MY_GITHUB_RUNNER_ID" =~ ^[1-9][0-9]*$ ]] || { echo >&2 "Ambiguous runner name; refusing registration deletion."; return 1; }
	cleanup_request -X DELETE -H "Accept: application/vnd.github+json" \
		-H "Authorization: Bearer ${MY_GITHUB_TOKEN}" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"https://api.github.com/repos/${MY_GITHUB_REPOSITORY}/actions/runners/${MY_GITHUB_RUNNER_ID}" || return 1
	# GitHub 404 can hide authorization errors; rediscovery on retry proves absence.
	[[ "$MY_HTTP_STATUS" == "204" ]] || return 1
	echo "GitHub Actions Runner deleted successfully."
}

MY_REGISTRATION_ONLY=${INPUT_REGISTRATION_ONLY:-false}
[[ "$MY_REGISTRATION_ONLY" == "true" || "$MY_REGISTRATION_ONLY" == "false" ]] || exit_with_failure "registration_only must be true or false."
if [[ "$MY_REGISTRATION_ONLY" == "true" && ( "$MY_MODE" != "delete" || -n "$MY_HETZNER_SERVER_ID" ) ]]; then
	exit_with_failure "registration_only requires delete mode and no server_id."
fi
if [[ "$MY_MODE" == "delete" ]]; then
	[[ -n "${INPUT_NAME:-}" ]] || exit_with_failure "An explicit name is required for deletion."
	if [[ "$MY_REGISTRATION_ONLY" == "false" && ! "$MY_HETZNER_SERVER_ID" =~ ^[1-9][0-9]*$ ]]; then
		exit_with_failure "A positive server_id is required for deletion."
	fi
	MY_DELETE_FAILED=false
	if [[ "$MY_REGISTRATION_ONLY" == "false" ]]; then
		delete_server || { echo >&2 "Server cleanup failed or is unknown."; MY_DELETE_FAILED=true; }
	fi
	delete_registration || { echo >&2 "Registration cleanup failed or is unknown."; MY_DELETE_FAILED=true; }
	[[ "$MY_DELETE_FAILED" == "false" ]] || exit_with_failure "Cleanup incomplete; retry with the same identity."
	if [[ "$MY_REGISTRATION_ONLY" == "true" ]]; then
		MY_SUMMARY="Registration cleanup complete. VM state was not checked or changed."
	else
		MY_SUMMARY="Server cleanup accepted or already absent; registration cleanup complete."
	fi
	echo "$MY_SUMMARY"
	echo "$MY_SUMMARY" >> "$GITHUB_STEP_SUMMARY"
	exit 0
fi

#
# CREATE
#

# Create GitHub Actions registration token for registering a self-hosted runner to a repository
# https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository
echo "Create GitHub Actions Runner registration token..."
curl -L \
	-X "POST" \
	--fail-with-body \
	-o "registration-token.json" \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: Bearer ${MY_GITHUB_TOKEN}" \
	-H "X-GitHub-Api-Version: 2022-11-28" \
	"https://api.github.com/repos/${MY_GITHUB_REPOSITORY}/actions/runners/registration-token" \
	|| exit_with_failure "Failed to retrieve GitHub Actions Runner registration token!"

# Read the GitHub Runner registration token from a file (assuming valid JSON)
MY_GITHUB_RUNNER_REGISTRATION_TOKEN=$(jq -er '.token' < "registration-token.json")

# Encode the contents of the "install.sh" and runner script into base64
# BSD
if [[ "$OSTYPE" == "darwin"* || "$OSTYPE" == "freebsd"* ]]; then
	MY_INSTALL_SH_BASE64=$(base64 < "install.sh")
	MY_PRE_RUNNER_SCRIPT_BASE64=$(echo "$MY_PRE_RUNNER_SCRIPT" | base64)
# GNU Core tools
else
	MY_INSTALL_SH_BASE64=$(base64 --wrap=0 < "install.sh")
	MY_PRE_RUNNER_SCRIPT_BASE64=$(echo "$MY_PRE_RUNNER_SCRIPT" | base64 --wrap=0)
fi
# Split repository into owner and repository name
MY_GITHUB_OWNER="${MY_GITHUB_REPOSITORY%/*}"   # Extract the part before the last /
MY_GITHUB_REPO_NAME="${MY_GITHUB_REPOSITORY##*/}"   # Extract the part after the last /

# Export environment variables for use in the cloud-init template
export MY_GITHUB_OWNER
export MY_GITHUB_REPO_NAME
export MY_GITHUB_REPOSITORY
export MY_GITHUB_RUNNER_REGISTRATION_TOKEN
export MY_INSTALL_SH_BASE64
export MY_NAME
export MY_PRE_RUNNER_SCRIPT_BASE64
export MY_RUNNER_DIR
export MY_RUNNER_VERSION
# Substitute environment variables in the cloud-init template and create the final cloud-init configuration
if [[ ! -f "cloud-init.template.yml" ]]; then
	exit_with_failure "cloud-init.template.yml not found!"
fi
envsubst < cloud-init.template.yml > cloud-init.yml

# Generate the create-server.json file by populating the create-server.template.json template with variables.
# This uses jq to construct a JSON object based on the template and provided arguments.
# Optimize values for valid labels: https://docs.hetzner.cloud/#labels
echo "Generate server configuration..."
jq -n \
	--arg     location        "$MY_LOCATION" \
	--arg     runner_version  "$MY_RUNNER_VERSION" \
	--arg     github_owner_id "$MY_GITHUB_REPOSITORY_OWNER_ID" \
	--arg     github_repo_id  "$MY_GITHUB_REPOSITORY_ID" \
	--arg     image           "$MY_IMAGE" \
	--arg     server_type     "$MY_SERVER_TYPE" \
	--arg     name            "$MY_NAME" \
	--argjson enable_ipv4     "$MY_ENABLE_IPV4" \
	--argjson enable_ipv6     "$MY_ENABLE_IPV6" \
	--rawfile cloud_init_yml  "cloud-init.yml" \
	-f create-server.template.json > create-server.json \
	|| exit_with_failure "Failed to generate create-server.json!"
# Add the primary IPv4 address if available (not "null")
if [[ "$MY_PRIMARY_IPV4" != "null" ]]; then
	cp create-server.json create-server-ipv4.json && \
	jq ".public_net.ipv4 = $MY_PRIMARY_IPV4" < create-server-ipv4.json > create-server.json && \
	echo "Primary IPv4 ID added to create-server.json."
fi
# Add the primary IPv6 address if available (not "null")
if [[ "$MY_PRIMARY_IPV6" != "null" ]]; then
	cp create-server.json create-server-ipv6.json && \
	jq ".public_net.ipv6 = $MY_PRIMARY_IPV6" < create-server-ipv6.json > create-server.json && \
	echo "Primary IPv6 ID added to create-server.json."
fi
# Add network configuration to the create-server.json file if MY_NETWORKS is not "null".
if [[ "$MY_NETWORKS" != "null" && -z "$MY_PRIVATE_IPV4" ]]; then
	cp create-server.json create-server-network.json && \
	jq ".networks += [$MY_NETWORKS]" < create-server-network.json > create-server.json && \
	echo "Networks added to create-server.json."
fi
if [[ "$MY_FIREWALLS" != "null" ]]; then
	cp create-server.json create-server-firewall.json || exit_with_failure "Failed to copy server configuration."
	jq --argjson ids "[$MY_FIREWALLS]" '.firewalls = ($ids | map({firewall: .}))' \
		< create-server-firewall.json > create-server.json || exit_with_failure "Failed to add firewalls."
fi
# Fixed-IP guests must not boot cloud-init before their network is attached.
if [[ -n "$MY_PRIVATE_IPV4" ]]; then
	cp create-server.json create-server-stopped.json || exit_with_failure "Failed to copy server configuration."
	jq '.start_after_create = false' < create-server-stopped.json > create-server.json \
		|| exit_with_failure "Failed to disable automatic start."
fi
# Add SSH key configuration to the create-server.json file if MY_SSH_KEYS is not "null".
if [[ "$MY_SSH_KEYS" != "null" ]]; then
	cp create-server.json create-server-ssh.json && \
	jq ".ssh_keys += [$MY_SSH_KEYS]" < create-server-ssh.json > create-server.json && \
	echo "SSH keys added to create-server.json."
fi
# Add volume configuration to the create-server.json file if MY_VOLUMES is not "null".
if [[ "$MY_VOLUMES" != "null" ]]; then
	cp create-server.json create-server-volume.json && \
	jq ".volumes += [$MY_VOLUMES]" < create-server-volume.json > create-server.json && \
	echo "Volumes added to create-server.json."
fi

# Send a POST request to the Hetzner Cloud API to create a server.
# https://docs.hetzner.cloud/#servers-create-a-server
MAX_RETRIES=$MY_CREATE_WAIT
RETRY_COUNT=0
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
	echo "Create Server..."
	if curl \
	-X POST \
	--fail-with-body \
	-o "servers.json" \
	-H "Content-Type: application/json" \
	-H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
	-d @create-server.json \
	"https://api.hetzner.cloud/v1/servers"; then
		echo "Server creation accepted."
		break
	else
		# Check if the error is related to resource unavailability
		# Workaround for https://status.hetzner.com/incident/aa5ce33b-faa5-4fd0-9782-fde43cd270cf
		if grep -q -E "resource_unavailable|resource_limit_exceeded" "servers.json"; then
			echo "Resource limitation detected."
		# If error is not resource-related, don't retry
		else
			cat "servers.json"
			exit_with_failure "Failed to create Server in Hetzner Cloud!"
		fi
	fi

	RETRY_COUNT=$((RETRY_COUNT + 1)) # Increment retry counter

	echo "Failed to create Server. Wait $WAIT_SEC seconds... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
	sleep "$WAIT_SEC"
done

# Get the Hetzner Server ID from the JSON response (assuming valid JSON)
MY_HETZNER_SERVER_ID=$(jq -er '.server.id' < "servers.json")

# Check if MY_HETZNER_SERVER_ID is an integer
if [[ ! "$MY_HETZNER_SERVER_ID" =~ ^[0-9]+$ ]]; then
	exit_with_failure "Failed to get ID of the Hetzner Cloud Server!"
fi

# Set GitHub Action output
# https://github.blog/changelog/2022-10-11-github-actions-deprecating-save-state-and-set-output-commands/
#echo "::set-output name=label::$MY_NAME"
#echo "::set-output name=server_id::$MY_HETZNER_SERVER_ID"
echo "label=$MY_NAME" >> "$GITHUB_OUTPUT"
echo "server_id=$MY_HETZNER_SERVER_ID" >> "$GITHUB_OUTPUT"

# Fixed-IP lifecycle calls use bounded requests and fail closed on unknown states.
function wait_private_server() {
	local target=$1 pending=$2 attempt status
	local deadline=$((SECONDS + 300))
	for ((attempt=0; attempt<MY_SERVER_WAIT; attempt++)); do
		((SECONDS < deadline)) || return 1
		cleanup_request -H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
			"https://api.hetzner.cloud/v1/servers/$MY_HETZNER_SERVER_ID" || return 1
		[[ "$MY_HTTP_STATUS" == "200" ]] || return 1
		status=$(jq -er --argjson id "$MY_HETZNER_SERVER_ID" \
			'.server | select(.id == $id) | .status' <<< "$MY_HTTP_BODY") || return 1
		[[ "$status" != "$target" ]] || return 0
		[[ "$status" == "$pending" ]] || return 1
		sleep "$WAIT_SEC"
	done
	return 1
}

# Handle one accepted mutation, never blindly retry its POST.
function wait_private_action() {
	local id status attempt
	local deadline=$((SECONDS + 300))
	id=$(jq -er '.action.id | numbers | select(. > 0 and floor == .)' <<< "$MY_HTTP_BODY") || return 1
	status=$(jq -er '.action.status' <<< "$MY_HTTP_BODY") || return 1
	[[ "$status" == "running" || "$status" == "success" ]] || return 1
	for ((attempt=0; attempt<MY_SERVER_WAIT; attempt++)); do
		((SECONDS < deadline)) || return 1
		cleanup_request -H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
			"https://api.hetzner.cloud/v1/actions/$id" || return 1
		[[ "$MY_HTTP_STATUS" == "200" ]] || return 1
		status=$(jq -er --argjson id "$id" '.action | select(.id == $id) | .status' <<< "$MY_HTTP_BODY") || return 1
		case "$status" in
		success) return 0 ;;
		running) sleep "$WAIT_SEC" ;;
		*) return 1 ;;
		esac
	done
	return 1
}

if [[ -n "$MY_PRIVATE_IPV4" ]]; then
	wait_private_server off initializing || exit_with_failure "Server did not become off; clean up server_id."
	MY_ATTACH_BODY=$(jq -n --argjson network "$MY_NETWORKS" --arg ip "$MY_PRIVATE_IPV4" '{network: $network, ip: $ip}') || exit_with_failure "Invalid attachment payload."
	cleanup_request -X POST -H "Content-Type: application/json" \
		-H "Authorization: Bearer ${MY_HETZNER_TOKEN}" -d "$MY_ATTACH_BODY" \
		"https://api.hetzner.cloud/v1/servers/$MY_HETZNER_SERVER_ID/actions/attach_to_network" \
		|| exit_with_failure "Network attachment transport failure; server_id output remains available for cleanup."
	[[ "$MY_HTTP_STATUS" == "201" ]] || exit_with_failure "Network attachment failed; clean up server_id."
	wait_private_action || exit_with_failure "Network attachment action failed or timed out."
	cleanup_request -H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
		"https://api.hetzner.cloud/v1/servers/$MY_HETZNER_SERVER_ID" || exit_with_failure "Cannot verify private IP."
	[[ "$MY_HTTP_STATUS" == "200" ]] || exit_with_failure "Cannot verify private IP status."
	jq -e --argjson id "$MY_HETZNER_SERVER_ID" --argjson network "$MY_NETWORKS" --arg ip "$MY_PRIVATE_IPV4" \
		'.server | .id == $id and .status == "off" and
		([.private_net[] | select(.network == $network and .ip == $ip)] | length == 1)' \
		<<< "$MY_HTTP_BODY" >/dev/null || exit_with_failure "Exact private IP/off verification failed."
	cleanup_request -X POST -H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
		"https://api.hetzner.cloud/v1/servers/$MY_HETZNER_SERVER_ID/actions/poweron" \
		|| exit_with_failure "Power on transport failure; clean up server_id."
	[[ "$MY_HTTP_STATUS" == "201" ]] || exit_with_failure "Power on failed; clean up server_id."
	wait_private_action || exit_with_failure "Power on action failed or timed out."
	wait_private_server running starting || exit_with_failure "Server did not become running; clean up server_id."
else
	# Wait for server
	MAX_RETRIES=$MY_SERVER_WAIT
	RETRY_COUNT=0
	echo "Wait for server..."
	while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
		# Download and parse server status
		# https://docs.hetzner.cloud/#servers-get-a-server
		curl -s \
			-o "servers.json" \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer ${MY_HETZNER_TOKEN}" \
			"https://api.hetzner.cloud/v1/servers/$MY_HETZNER_SERVER_ID" \
			|| exit_with_failure "Failed to get status of the Hetzner Cloud Server!"

		MY_HETZNER_SERVER_STATUS=$(jq -er '.server.status' < "servers.json")

		# Check if server is running
		if [[ "$MY_HETZNER_SERVER_STATUS" == "running" ]]; then
			echo "Server is running."
			break
		fi

		RETRY_COUNT=$((RETRY_COUNT + 1)) # Increment retry counter

		echo "Server is not running yet. Waiting $WAIT_SEC seconds... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
		sleep "$WAIT_SEC"
	done
	if [[ "$MY_HETZNER_SERVER_STATUS" != "running" ]]; then
		exit_with_failure "Failed to start Hetzner Cloud Server! Please check manually."
	fi

fi

# Wait for GitHub Actions Runner registration
MAX_RETRIES=$MY_RUNNER_WAIT
RETRY_COUNT=0
echo "Wait for GitHub Actions Runner registration..."
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
	# List self-hosted runners for repository
	# https://docs.github.com/en/rest/actions/self-hosted-runners?apiVersion=2022-11-28#list-self-hosted-runners-for-a-repository
	curl -L -s \
		-o "github-runners.json" \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: Bearer ${MY_GITHUB_TOKEN}" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"https://api.github.com/repos/${MY_GITHUB_REPOSITORY}/actions/runners" \
		|| exit_with_failure "Failed to list GitHub Actions runners from repository!"

	MY_GITHUB_RUNNER_ID=$(jq -er ".runners[] | select(.name == \"$MY_NAME\") | .id" < "github-runners.json")
	# Check if MY_GITHUB_RUNNER_ID is an integer
	if [[ "$MY_GITHUB_RUNNER_ID" =~ ^[0-9]+$ ]]; then
		echo "GitHub Actions Runner registered."
		break
	fi

	RETRY_COUNT=$((RETRY_COUNT + 1)) # Increment retry counter

	echo "GitHub Actions Runner is not yet registered. Wait $WAIT_SEC seconds... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
	sleep "$WAIT_SEC"
done
if [[ ! "$MY_GITHUB_RUNNER_ID" =~ ^[0-9]+$ ]]; then
	exit_with_failure "GitHub Actions Runner is not registered. Please check installation manually."
fi

echo
echo "The Hetzner Cloud Server and its associated GitHub Actions Runner are ready for use."
echo "Runner: https://github.com/${MY_GITHUB_REPOSITORY}/settings/actions/runners/${MY_GITHUB_RUNNER_ID}"
# Add GitHub Action job summary
# https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#adding-a-job-summary
echo "The Hetzner Cloud Server and its associated [GitHub Actions Runner](https://github.com/${MY_GITHUB_REPOSITORY}/settings/actions/runners/${MY_GITHUB_RUNNER_ID}) are ready for use 🚀" >> "$GITHUB_STEP_SUMMARY"
exit 0
