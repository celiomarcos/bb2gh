#!/bin/bash

# don't process these repositories
ignore_list=("springboard" "springboard-library" "springboard-sites" "rundeckjobs2")

pages=1 # increase if has more than 100 repos

log_file="migration.log"

log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
}

log_info() { log "INFO" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_error() { log "ERROR" "$1"; }

log_info "Starting repository migration script."

if [ -f .env ]
then
    set -o allexport
    source .env
    set +o allexport
    log_info ".env file loaded successfully."
else
    log_error ".env file not found. Please create one with BB_USERNAME, BB_PASSWORD, BB_ORGANIZATION, GH_USERNAME, GH_TOKEN, and GH_ORGANIZATION."
    exit 1
fi

if [ -z "$BB_USERNAME" ] || [ -z "$BB_PASSWORD" ] || [ -z "$BB_ORGANIZATION" ] || [ -z "$GH_USERNAME" ] || [ -z "$GH_TOKEN" ] || [ -z "$GH_ORGANIZATION" ]; then
    log_error "One or more required environment variables (BB_USERNAME, BB_PASSWORD, BB_ORGANIZATION, GH_USERNAME, GH_TOKEN, GH_ORGANIZATION) are not set."
    exit 1
fi

set -e

mkdir -p repos || { log_error "Failed to create 'repos' directory."; exit 1; }
log_info "Created or ensured 'repos' directory exists."

for (( page=1; page<=$pages; page++ ))
do
    log_info "Processing page $page of Bitbucket repositories for organization $BB_ORGANIZATION."
    
    bitbucket_repos_response=$(curl -s -f --user "$BB_USERNAME:$BB_PASSWORD" "https://api.bitbucket.org/2.0/repositories/$BB_ORGANIZATION?pagelen=100&page=$page")
    
    if [ $? -ne 0 ]; then
        log_error "Failed to fetch repositories from Bitbucket API (page $page). Check credentials and organization name."
        continue # Or exit 1
    fi

    repos=$(echo "$bitbucket_repos_response" | jq ".values[].full_name" -r)
    
    if [ $? -ne 0 ]; then
        log_error "Failed to parse repository names from Bitbucket API response using jq (page $page). Is jq installed and the API response format as expected?"
        continue # Or exit 1
    fi
    
    if [ -z "$repos" ]; then
        log_info "No repositories found on page $page or end of repositories reached."
        break
    fi

    echo "$repos" | while read -r org_repo
    do
        repo_name=${org_repo#"$BB_ORGANIZATION/"}
        log_info "Processing repository: $repo_repo"

        if [[ " ${ignore_list[@]} " =~ " ${repo_name} " ]]; then
            log_warning "Skipping repository '$repo_name' as it is in the ignore list."
            continue
        fi

        if [ -d "repos/$repo_name" ]; then
            log_info "Skipping repository '$repo_name' as it has already been cloned locally."
            continue
        fi

        log_info "Cloning bare repository '$org_repo' from Bitbucket."
        if ! git clone -q --bare "https://$BB_USERNAME:$BB_PASSWORD@bitbucket.org/$org_repo" "repos/$repo_name"; then
            log_error "Failed to clone repository '$org_repo' from Bitbucket."
            # next repo or exit?
            continue
        fi
        log_info "Successfully cloned '$repo_name'."

        log_info "Checking if repository '$repo_name' exists in GitHub organization '$GH_ORGANIZATION'."

        github_check_status=$(curl -s -o /dev/null -w '%{http_code}' --user "$GH_USERNAME:$GH_TOKEN" "https://api.github.com/repos/$GH_ORGANIZATION/$repo_name")

        case "$github_check_status" in
            "200")
                log_info "Repository '$repo_name' already exists in GitHub. Skipping creation and push."
                ;;
            "404")
                log_info "Repository '$repo_name' not found in GitHub. Proceeding to create it."
                
                log_info "Creating repository '$repo_name' in GitHub organization '$GH_ORGANIZATION'."
                github_create_response=$(curl -s -X POST --user "$GH_USERNAME:$GH_TOKEN" "https://api.github.com/orgs/$GH_ORGANIZATION/repos" -d "{\"name\": \"$repo_name\", \"private\": true}")
                github_create_status=$(echo "$github_create_response" | head -n 1 | cut -d' ' -f2)

                if echo "$github_create_response" | jq '.html_url' -r | grep -q "github.com"; then
                     log_info "Successfully created GitHub repository: $(echo "$github_create_response" | jq '.html_url' -r)"
                     
                     log_info "Pushing repository '$repo_name' to GitHub."
                     cd "repos/$repo_name" || { log_error "Failed to change directory to repos/$repo_name."; continue; }
                     
                     if ! git push --quiet --mirror "https://$GH_USERNAME:$GH_TOKEN@github.com/$GH_ORGANIZATION/$repo_name.git"; then
                         log_error "Failed to push repository '$repo_name' to GitHub."
                         cd ../.. || log_error "Failed to change directory back from repos/$repo_name." # Attempt to go back
                         continue
                     fi
                     log_info "Successfully pushed '$repo_name' to GitHub."
                     cd ../.. || log_error "Failed to change directory back from repos/$repo_name." # Always attempt to go back
                else
                    log_error "Failed to create GitHub repository '$repo_name'. Response: $github_create_response"
                    # check specific error messages in the response here
                    continue
                fi
                ;;
            *)
                log_error "Failed to check existence of '$repo_name' in GitHub. Received status code: $github_check_status. Response: $(curl -s --user "$GH_USERNAME:$GH_TOKEN" "https://api.github.com/repos/$GH_ORGANIZATION/$repo_name")"
                # next repo or exit?
                continue
                ;;
        esac
    done
done

# Clean up the cloned repositories directory
log_info "Cleaning up local repositories directory: repos"
if ! rm -rf repos; then
    log_warning "Failed to remove 'repos' directory. Manual cleanup may be required."
else
    log_info "'repos' directory removed successfully."
fi

log_info "Repository migration script finished."
