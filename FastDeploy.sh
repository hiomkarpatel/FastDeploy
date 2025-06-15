#!/bin/bash

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Initialize early to an empty string for safer cleanup on early errors
APP_CODE_NAME=""
APP_DIR="" # Will be /var/www/$APP_CODE_NAME
INSTALLATION_MODE=""
ACTION_COMPLETED_APP_CLEARED="false"
SCRIPT_EXITING_CLEANLY_AFTER_USER_ACTION="false"
KNOWN_SERVICE_PORTS=(20 21 22 25 53 80 110 143 443 465 587 993 995 3306 5432 6379 27017 11211)

# Function for colored echo
color_echo() {
    echo -e "${YELLOW}[INFO] $1${NC}"
}

execute_quietly() {
    local description="$1"
    shift # Remove description

    local print_generic_success_msg_flag="true" # Default: print "completed successfully"
    # Check if the next argument is 'false' to suppress the success message
    if [[ $# -gt 0 && "$1" == "false" ]]; then
        print_generic_success_msg_flag="false"
        shift # Consume the 'false' flag
    elif [[ $# -gt 0 && "$1" == "true" ]]; then # Explicit 'true'
        shift # Consume the 'true' flag
    fi
    local command_to_run=("$@")

    color_echo "${description}..."

    local temp_log
    temp_log=$(mktemp) # Create a temporary file for logs from the command

    # Execute the command, redirecting all its output to the temp_log
    if ! "${command_to_run[@]}" >"$temp_log" 2>&1; then
        echo -e "${RED}ERROR: Task '$description' failed.${NC}"
        echo -e "${RED}Command executed: ${command_to_run[*]}${NC}"
        echo -e "${YELLOW}Output from command (last 20 lines):${NC}"
        tail -n 20 "$temp_log" # Show the tail of the log for quick diagnosis
        echo -e "${YELLOW}Full output for this command was in: $temp_log (this file will be removed).${NC}"
        echo -e "${YELLOW}If script logging is enabled, check the main log file for more context.${NC}"
        rm -f "$temp_log" # Clean up the temp file
        exit 1 # Critical failure, exit script
    fi

    rm -f "$temp_log" # Clean up temp file on success
    if [ "$print_generic_success_msg_flag" = "true" ]; then
        color_echo "$description completed successfully."
    fi
}

# Cleanup function
cleanup() {
    if [ "${SCRIPT_EXITING_CLEANLY_AFTER_USER_ACTION}" = "true" ]; then
        return
    fi
    if [ -z "$APP_CODE_NAME" ]; then
        if [ "${ACTION_COMPLETED_APP_CLEARED}" != "true" ]; then
            echo -e "${YELLOW}\nSkipping cleanup(No action performed on Server by FastDeploy.)${NC}"
        fi
        return
    fi
    echo -e "${RED}Performing cleanup for '$APP_CODE_NAME'${NC}"
    # Commands to undo changes here
    sudo systemctl stop "$APP_CODE_NAME.service" 2>/dev/null || true
    sudo systemctl disable "$APP_CODE_NAME.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$APP_CODE_NAME.service"
    sudo rm -f "/etc/nginx/sites-available/$APP_CODE_NAME"
    sudo rm -f "/etc/nginx/sites-enabled/$APP_CODE_NAME"
    if systemctl is-active --quiet nginx; then # Reload nginx only if it's active
      sudo systemctl reload nginx 2>/dev/null || echo -e "${YELLOW}Nginx reload might have failed or Nginx not running.${NC}"
    fi
    sudo userdel -r "$APP_CODE_NAME" 2>/dev/null || true
    sudo rm -rf "$APP_DIR" # Use APP_DIR variable
    echo -e "${RED}Cleanup completed for '$APP_CODE_NAME'.${NC}"
}

# Set trap to call cleanup function on error or exit
trap cleanup ERR EXIT # Also run on normal exit if something needs undoing if not fully complete

# Function to Check and Update system packages
check_update_system() {
    execute_quietly "Updating package lists" sudo apt-get update -y
    if [ "$(apt list --upgradable 2>/dev/null | grep -vc "Listing...")" -gt 0 ]; then
        color_echo "Package updates are available."
        execute_quietly "Upgrading system packages" sudo apt-get upgrade -y
        execute_quietly "Performing system cleanup (autoremove)" sudo apt-get autoremove -y
        color_echo "System update and upgrade process finished."
    else
        color_echo "No updates available. System is up to date."
    fi
}

# Function to check and install nginx
check_install_nginx() {
    if ! command -v nginx &> /dev/null; then
        execute_quietly "Installing Nginx" sudo apt-get install -y nginx
    else
        color_echo "Nginx is already installed."
    fi

    color_echo "Ensuring Nginx is enabled and started..."
    # systemctl output is usually minimal, but can be wrapped if too noisy.
    # For now, let's keep its direct output for clarity on service status.
    if ! sudo systemctl enable --now nginx; then # Output is usually minimal and useful
        echo -e "${RED}Failed to start or enable Nginx. Aborting.${NC}"
        exit 1
    fi
    color_echo "Nginx is running."
}

# Function to check and install Certbot and its Nginx plugin
check_install_certbot() {
    # Check for the certbot command
    if ! command -v certbot &> /dev/null; then
        # Check if the Nginx plugin package is available/installed via dpkg
        # Sometimes certbot might be installed via pip or snap, but we want the apt package for integration here.
        if ! dpkg -s python3-certbot-nginx &> /dev/null; then
            color_echo "Certbot or its Nginx plugin not found. Installing..."
            execute_quietly "Installing Certbot and Nginx plugin (certbot python3-certbot-nginx)" sudo apt-get install -y certbot python3-certbot-nginx
        else
            # This case is rare: Nginx plugin is there but certbot command is not. Still try installing.
            execute_quietly "Installing Certbot" sudo apt-get install -y certbot
        fi
    else
        color_echo "Certbot is already installed."
    fi
}

# Function to check and install python3-venv
check_install_python_venv() {
    if ! dpkg -s python3-venv &> /dev/null; then
        execute_quietly "Installing python3-venv" sudo apt-get install -y python3-venv
    else
        color_echo "python3-venv is already installed."
    fi
}

# Function to check if a port is in use
check_port_in_use() {
    if sudo lsof -Pi :"$1" -sTCP:LISTEN -t >/dev/null ; then
        return 0 # In use
    else
        return 1 # Not in use
    fi
}

generate_available_port() {
    local port
    local max_attempts=50
    local attempt=0
    # Send this informational message to stderr so it doesn't get captured by command substitution
    echo -e "${YELLOW}[INFO] Attempting to find an available random port...${NC}" >&2 

    while [ "$attempt" -lt "$max_attempts" ]; do
        port=$(( ( RANDOM % (65535 - 1024 + 1) ) + 1024 )) # Ports 1024-65535

        local is_known_service_port=false
        for known_port in "${KNOWN_SERVICE_PORTS[@]}"; do
            if [ "$port" -eq "$known_port" ]; then
                is_known_service_port=true
                break
            fi
        done

        if [ "$is_known_service_port" = true ]; then
            attempt=$((attempt + 1))
            continue # Skip known service ports
        fi

        if ! check_port_in_use "$port"; then # If NOT in use
            echo "$port" # THIS is the only stdout output for successful port finding
            return 0 # Success
        fi
        attempt=$((attempt + 1))
    done
    # Fallback if no port found after attempts
    echo -e "${RED}[ERROR] Could not automatically find an available port after $max_attempts attempts.${NC}" >&2
    echo "" # Return empty on stdout to indicate failure
    return 1 # Failure
}

# Main function
main() {
    # Function to get user input with validation and default values
    get_input() {
        local prompt_text="${1:-}"
        local var_name="${2:-}"
        local validation_func="${3:-}"
        local original_explanation="${4:-}"
        local default_value="${5:-}"
        local is_sensitive="${6:-false}"
        local input_val

        # Clean the explanation: remove leading spaces and tabs from each line
        # The `echo "$original_explanation"` ensures multi-line strings are processed correctly by sed
        explanation=$(echo "$original_explanation" | sed 's/^[ \t]*//')

        if [ "$INSTALLATION_MODE" = "Easy" ] && [ -n "$default_value" ]; then
            printf -v "$var_name" '%s' "$default_value"
            echo "Using default value for $var_name: $default_value"
        else
            echo -e "${GREEN}$explanation${NC}"
            local effective_default="$default_value"
            
            local read_opts_array=()
            local sensitive_prompt_suffix=""

            if [ "$is_sensitive" = "true" ]; then
                read_opts_array+=(-s)
                sensitive_prompt_suffix=" (input hidden)" 
            fi

            if [ -n "$effective_default" ]; then
                local current_prompt_str 
                if [ "$is_sensitive" = "true" ]; then
                    current_prompt_str="$prompt_text (default is set, input hidden): "
                else
                    current_prompt_str="$prompt_text (default: $effective_default): "
                fi
                
                read -p "$current_prompt_str" "${read_opts_array[@]}" input_val
                if [ "$is_sensitive" = "true" ]; then echo; fi # Newline after sensitive input

                if [ -z "$input_val" ]; then
                    input_val="$effective_default"
                fi
            else
                while true; do # Loop until valid input if no default or default not chosen
                    read -p "$prompt_text$sensitive_prompt_suffix: " "${read_opts_array[@]}" input_val
                    if [ "$is_sensitive" = "true" ]; then echo; fi
                    if [ -n "$input_val" ]; then break; fi # Basic check: not empty
                    echo -e "${RED}Input cannot be empty.${NC}"
                done
            fi

            # Validation loop
            if [ -n "$validation_func" ]; then
                while ! $validation_func "$input_val"; do
                    echo -e "${RED}Invalid input. Please try again.${NC}"
                    # For validation re-prompts, also use base prompt_text and append suffix if sensitive
                    read -p "$prompt_text$sensitive_prompt_suffix: " "${read_opts_array[@]}" input_val
                    if [ "$is_sensitive" = "true" ]; then echo; fi
                    
                    # If they entered nothing and there was a default, re-apply default and re-validate
                    if [ -z "$input_val" ] && [ -n "$effective_default" ]; then
                        input_val="$effective_default"
                    elif [ -z "$input_val" ]; then # If no default and empty input
                        echo -e "${RED}Input cannot be empty.${NC}"
                        continue # Re-prompt
                    fi
                done
            fi
            printf -v "$var_name" '%s' "$input_val"
        fi

        if [ "$is_sensitive" = "false" ]; then
            echo -e "${YELLOW}$var_name set to: ${!var_name}${NC}"
        else
            echo -e "${YELLOW}$var_name has been set (value hidden).${NC}"
        fi
        echo # Add a newline for readability
    }

    # Validation functions
    validate_port() {
        [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
    }
    validate_integer() { [[ $1 =~ ^[0-9]+$ ]]; }
    validate_percentage() { [[ $1 =~ ^[0-9]{1,3}%$ ]] && [ "${1%\%}" -ge 0 ] && [ "${1%\%}" -le 100 ]; } # Allow 0-100%
    validate_nice_value() { [[ $1 =~ ^-?[0-9]+$ ]] && [ "$1" -ge -20 ] && [ "$1" -le 19 ]; }
    validate_app_code_name() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]] && [[ ! "$1" =~ \.\. ]]; } # Basic validation
    validate_domain_name() { [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; } # Basic domain check
    validate_not_empty() { [ -n "$1" ]; } # Simple not empty validation
    validate_github_url() {
        [[ "$1" =~ ^https://github\.com/.+/.+(\.git)?$ ]] || [[ "$1" =~ ^git@github\.com:.+/.+(\.git)?$ ]];
    }
    validate_python_module_instance_format() {
        [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*:[a-zA-Z_][a-zA-Z0-9_]*$ ]]
    }

    # --- SCRIPT START ---
    clear
    echo -e "${GREEN}Welcome to the FastDeploy - FastAPI Application Deployment Script!${NC}"
    echo "This script will help you deploy a FastAPI application with Nginx and Systemd."
    echo -e "${YELLOW}You can press Ctrl+C/CMD+C at any point to abort the script. A cleanup will be attempted if necessary.${NC}"
    echo "--------------------------------------------------------------------------"

    # Choose mode
    while true; do
        read -p "Choose mode (Install/Uninstall) [I/u, default: I]: " MODE_CHOICE
        MODE_CHOICE=${MODE_CHOICE:-I}
        if [[ $MODE_CHOICE =~ ^[Ii]$ ]]; then
            MODE="Install"
            break
        elif [[ $MODE_CHOICE =~ ^[Uu]$ ]]; then
            MODE="Uninstall"
            break
        else
            echo -e "${RED}Invalid input. Please enter 'I' (Install) or 'U' (Uninstall).${NC}"
        fi
    done

    if [ "$MODE" = "Uninstall" ]; then
        get_input "Enter the app code name to uninstall" APP_CODE_NAME validate_app_code_name \
            "Enter the unique 'code name' of the application you wish to uninstall.
            This is the short, system-level name (e.g., \`my_cool_api\`, \`project_x_backend\`)
            used when the application was initially installed. It identifies its systemd
            service, Nginx configuration, system user, and application directory
            (e.g., /var/www/app_code_name)."
        if [ -z "$APP_CODE_NAME" ]; then
            echo -e "${RED}No app code name provided or obtained. Cannot proceed with uninstall.${NC}"
            exit 1 
        fi

        APP_DIR="/var/www/$APP_CODE_NAME" 
        echo -e "${YELLOW}You are about to uninstall '$APP_CODE_NAME'. This will remove:"
        echo "- Systemd service: $APP_CODE_NAME.service"
        echo "- Nginx site: $APP_CODE_NAME"
        echo "- System user: $APP_CODE_NAME"
        echo "- Application directory: $APP_DIR"
        
        local confirm_uninstall=""
        read -p "Are you sure you want to proceed? [y/N]: " confirm_uninstall
        
        if [[ $confirm_uninstall =~ ^[Yy]$ ]]; then
            cleanup 
            echo -e "${GREEN}Uninstallation complete for '$APP_CODE_NAME'${NC}"
            ACTION_COMPLETED_APP_CLEARED="true" 
            APP_CODE_NAME="" 
            SCRIPT_EXITING_CLEANLY_AFTER_USER_ACTION="true" 
        else
            echo -e "${YELLOW}Uninstallation cancelled.${NC}"
            SCRIPT_EXITING_CLEANLY_AFTER_USER_ACTION="true" 
        fi
        exit 0 
    fi

    # --- INSTALLATION MODE ---
    color_echo "Starting Installation Process..."

    # Get installation mode
    while true; do
        read -p "Choose Installation Mode (Easy/Advanced) [E/a, default: E]: " INSTALLATION_MODE_CHOICE
        INSTALLATION_MODE_CHOICE=${INSTALLATION_MODE_CHOICE:-E}
        if [[ $INSTALLATION_MODE_CHOICE =~ ^[Ee]$ ]]; then
            INSTALLATION_MODE="Easy"
            break
        elif [[ $INSTALLATION_MODE_CHOICE =~ ^[Aa]$ ]]; then
            INSTALLATION_MODE="Advanced"
            break
        else
            echo -e "${RED}Invalid input. Please enter 'E' (Easy) or 'A' (Advanced).${NC}"
        fi
    done

    # Calculate recommended number of workers
    local num_cores
    num_cores=$(nproc)
    recommended_workers=$(($num_cores * 2 + 1))

    # Calculate dynamic defaults
    local TOTAL_MEM_MB
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}' 2>/dev/null)
    if ! [[ "$TOTAL_MEM_MB" =~ ^[0-9]+$ ]] || [ -z "$TOTAL_MEM_MB" ]; then
        TOTAL_MEM_MB=1024 # Fallback if 'free -m' fails or gives weird output
        color_echo "${YELLOW}Could not reliably determine total system memory. Assuming ${TOTAL_MEM_MB}MB for suggestions.${NC}"
    fi

    # Suggest MemoryMax as 1/8th of total RAM, with a minimum of 256M and max of e.g. 4G for this default
    local RECOMMENDED_MEM_MAX_RAW=$((TOTAL_MEM_MB / 8))
    if [ "$RECOMMENDED_MEM_MAX_RAW" -lt 256 ]; then
        DEFAULT_MEMORY_MAX="256M"
    elif [ "$RECOMMENDED_MEM_MAX_RAW" -gt 4096 ]; then # Cap suggestion at 4G
        DEFAULT_MEMORY_MAX="4G"
    else
        DEFAULT_MEMORY_MAX="${RECOMMENDED_MEM_MAX_RAW}M"
    fi
    color_echo "Suggesting MemoryMax for systemd: $DEFAULT_MEMORY_MAX (based on ${TOTAL_MEM_MB}MB total RAM)"

    # Default values (some might be overridden by "Easy" mode in get_input)
    DEFAULT_NUM_WORKERS=$recommended_workers
    DEFAULT_CONCURRENCY_LIMIT=1000
    DEFAULT_BACKLOG_SIZE=2048
    DEFAULT_NICE_VALUE=0
    DEFAULT_CPU_QUOTA="80%"
    DEFAULT_NGINX_GZIP_COMP_LEVEL=6
    DEFAULT_APP_PORT=3456
    DEFAULT_UVICORN_APP_MODULE="main:app"

    # Get user inputs
    get_input "Enter the Nice name of the app" APP_NICE_NAME validate_not_empty \
        "\\nEnter a descriptive, human-readable name for your application.
        This name will be used in the description of the systemd service
        (e.g., 'My Awesome Product API'). It's for display purposes and helps
        identify the service. Example: \`Customer Data API\`, \`Internal Reporting Service\`."
    
    get_input "Enter the code name of the app" APP_CODE_NAME validate_app_code_name \
        "Enter a short, unique 'code name' for this application. This name will be
        used to create the system user, group, systemd service file (e.g., \`app_code_name.service\`),
        Nginx configuration file, and the application directory (e.g., \`/var/www/app_code_name\`).
        Rules: Use only letters, numbers, hyphens (\`-\`), underscores (\`_\`), and periods (\`.\`).
        No spaces or other special characters. Keep it relatively short.
        Examples: \`my_cool_api\`, \`projectx-backend\`, \`webapp01\`."
    APP_DIR="/var/www/$APP_CODE_NAME" # Set APP_DIR globally for cleanup and other functions

    get_input "Enter the GitHub repo URL (HTTPS or SSH)" GITHUB_REPO validate_github_url \
        "Enter the full Git repository URL for your FastAPI application.
        HTTPS: \`https://github.com/your_username/your_repository.git\`
            (For private HTTPS, you'll be prompted for username/PAT).
        SSH:   \`git@github.com:your_username/your_repository.git\`
            (Requires SSH key setup on this server for the user \`$APP_CODE_NAME\`).
        NOTE: The script performs a shallow clone (\`--depth 1\`) for faster deployment."
    
    if [[ "$GITHUB_REPO" == "https://"* ]]; then
        get_input "Enter your GitHub username (optional, for private HTTPS repos)" GITHUB_USERNAME "" \
            "If your GitHub repository (using HTTPS URL) is private, enter your GitHub username.
            Public HTTPS Repo or SSH URL: Leave this blank and press Enter.
            This username, with a Personal Access Token (PAT), authenticates private repo cloning."
        if [ -n "$GITHUB_USERNAME" ]; then
            get_input "Enter your GitHub Personal Access Token (PAT)" GITHUB_PAT validate_not_empty \
                "If you provided a GitHub username for a private HTTPS repo, enter your PAT.
                Input is hidden for security.
                A PAT is like a password with specific scopes (permissions). Create one in your
                GitHub settings (Developer settings -> Personal access tokens).
                Required PAT scope: \`repo\` (to clone private repositories).
                This PAT is used only for \`git clone\` and not stored permanently." "" "true"
        else
            GITHUB_PAT="" # Ensure it's empty if username is blank
        fi
    fi
    
    get_input "Enter the domain name" DOMAIN_NAME validate_domain_name \
        "Enter the domain name (or subdomain) to access your application (e.g., \`api.example.com\`).
        Nginx will listen for requests on this domain.
        Important: You must own this domain and configure its DNS 'A' record (or 'CNAME')
        to point to this server's public IP address *after* successful deployment.
        SSL setup guidance will be provided later."

    local suggested_port
    suggested_port=$(generate_available_port) 

    if [ -n "$suggested_port" ]; then
        DEFAULT_APP_PORT="$suggested_port"
        color_echo "Suggested available port for the app (Uvicorn): $DEFAULT_APP_PORT"
    else
        color_echo "${YELLOW}Falling back to default port 8000 as an available one could not be automatically determined.${NC}"
        DEFAULT_APP_PORT=8000 
    fi

    # The get_input will then use this clean DEFAULT_APP_PORT
    get_input "Enter the port for the app to run on" APP_PORT validate_port \
        "Enter the internal port (1024-65535) for your FastAPI app (Uvicorn).
        This port is *not* directly public; Nginx proxies requests from port 80/443 to it.
        The script suggested \`$DEFAULT_APP_PORT\`. Using this is often a good choice.
        Ensure this port is not already in use. The script will check." "$DEFAULT_APP_PORT"

    # Crucial: After user provides APP_PORT (even if it's the suggested one), re-check it
    if check_port_in_use "$APP_PORT"; then # Use the global port check function
        echo -e "${RED}Error: Port $APP_PORT is already in use. Please choose a different port.${NC}"
        exit 1
    fi

    get_input "Enter Python module and FastAPI instance (e.g., main:app)" UVICORN_APP_MODULE validate_python_module_instance_format \
        "Specify the Python module path and the FastAPI application instance Uvicorn should run.
        Format: \`path.to.module:fastapi_instance_variable_name\`.
        Example 1 (Default): If your FastAPI app is in \`main.py\` and the instance is \`app = FastAPI()\`,
                    enter \`main:app\`.
        Example 2 (Package): If app is in \`my_project/api/server.py\` and instance is \`my_api = FastAPI()\`,
                    enter \`my_project.api.server:my_api\`.
        This corresponds to the \`APP\` argument for the \`uvicorn\` command." "$DEFAULT_UVICORN_APP_MODULE"

    get_input "Enter the number of Uvicorn workers" NUM_WORKERS validate_integer \
        "Enter the number of Uvicorn worker processes. These handle requests concurrently.
        Recommendation: \`(2 * number_of_CPU_cores) + 1\`. This server has $num_cores core(s).
        The script calculated a recommendation of: \`$recommended_workers\`.
        Considerations:
        - CPU-bound apps: More workers (up to recommendation) can help.
        - I/O-bound apps: Uvicorn is efficient; start with recommendation, adjust with load testing.
        - Memory: Each worker consumes memory. Too many can cause issues on low-RAM servers." "$DEFAULT_NUM_WORKERS"

    get_input "Enter Uvicorn concurrency limit" CONCURRENCY_LIMIT validate_integer \
        "Max concurrent connections/requests each Uvicorn worker will handle.
        Uvicorn uses \`asyncio\` for many connections per worker. This limits simultaneous handling.
        Default (\`$DEFAULT_CONCURRENCY_LIMIT\`) is high, suitable for I/O-bound apps (many waiting connections).
        If app has long, CPU-intensive tasks per request, a lower limit might ensure fairer distribution.
        Total concurrent capacity ~ \`NUM_WORKERS\` * \`CONCURRENCY_LIMIT\`." "$DEFAULT_CONCURRENCY_LIMIT"

    get_input "Enter Uvicorn backlog size" BACKLOG_SIZE validate_integer \
        "Max incoming connections the OS queues for Uvicorn if all workers are busy (TCP socket backlog).
        Default (\`$DEFAULT_BACKLOG_SIZE\`) is common for web servers.
        If clients get connection timeouts during high traffic spikes, increasing *might* help,
        but it's usually better to optimize the app or add workers.
        Setting too high can mask underlying performance issues." "$DEFAULT_BACKLOG_SIZE"

    get_input "Enter systemd Nice value for the app" NICE_VALUE validate_nice_value \
        "Set 'niceness' for your app's processes, influencing CPU scheduling priority.
        Range: \`-20\` (highest priority) to \`19\` (lowest priority). \`0\` is normal.
        Negative (e.g., \`-5\`): Higher priority. Use cautiously; can starve other system processes.
        Positive (e.g., \`5\`): Lower priority. Good for background/less critical tasks.
        Default (\`$DEFAULT_NICE_VALUE\`) is usually safe." "$DEFAULT_NICE_VALUE"

    get_input "Enter systemd CPUQuota" CPU_QUOTA validate_percentage \
        "Set a CPU usage limit for your application, as a percentage of *one CPU core's capacity*.
        How it works: \`CPUQuota=X%\` means your app can use up to \`X%\` of one CPU core's power.
        This server has $num_cores core(s).
        - On a single-core server: \`80%\` means 80% of total CPU.
        - On a multi-core server (like this one with $num_cores cores):
            - \`80%\` limits the app to 0.8 of *one* core's capacity.
            - To use up to 2 full cores, set \`200%\`.
            - To allow your \`$NUM_WORKERS\` workers to potentially use most of the $num_cores cores (e.g., 80% of total capacity),
            you might set this to \`$(($num_cores * 80))%\`.
        Default suggestion for this server: \`$DEFAULT_CPU_QUOTA\` (which is $DEFAULT_CPU_QUOTA of one core).
        Consider app needs and if other services run on this server." "$DEFAULT_CPU_QUOTA"

    get_input "Enter systemd MemoryMax" MEMORY_MAX "" \
        "Set the maximum RAM your application can use (e.g., \`512M\`, \`2G\`).
        Format: Suffixes \`K\` (Kilobytes), \`M\` (Megabytes), \`G\` (Gigabytes).
        The script suggests \`$DEFAULT_MEMORY_MAX\` based on system RAM (${TOTAL_MEM_MB}MB total).
        Too low: App might be killed by system (OOM killer).
        Too high on shared server: Can starve other apps.
        Python apps with multiple workers can use significant memory. Monitor actual usage and adjust." "$DEFAULT_MEMORY_MAX"

    get_input "Enter NGINX gzip compression level (1-9)" NGINX_GZIP_COMP_LEVEL validate_integer \
        "Nginx Gzip compression level for text responses (HTML, CSS, JS, JSON).
        Range: \`1\` (lowest compression, fastest) to \`9\` (highest, slowest, more CPU).
        Default (\`$DEFAULT_NGINX_GZIP_COMP_LEVEL\`) is a balance of compression & CPU usage.
        Levels 1-3: Light on CPU. Levels 7-9: More CPU for diminishing returns.
        For most apps, 4-6 is optimal. If CPU constrained, consider lower (e.g., 4)." "$DEFAULT_NGINX_GZIP_COMP_LEVEL"

    # --- SYSTEM PREPARATION ---
    check_update_system
    check_install_nginx
    check_install_python_venv
    # Install Certbot automatically if in Easy Mode
    if [ "$INSTALLATION_MODE" = "Easy" ]; then
        check_install_certbot
    fi
    # Check if lsof is installed for port checking, install if not
    if ! command -v lsof &> /dev/null; then
        execute_quietly "Installing lsof for port checking" sudo apt-get install -y lsof
    fi

    if check_port_in_use "$APP_PORT"; then
        echo -e "${RED}Error: Port $APP_PORT is already in use. Please choose a different port.${NC}"
        exit 1
    fi

    # --- USER AND DIRECTORY SETUP ---
    color_echo "Creating system user '$APP_CODE_NAME' and group..."
    if ! sudo adduser --system --group --no-create-home --home "$APP_DIR" "$APP_CODE_NAME"; then # --no-create-home as we create $APP_DIR manually
        echo -e "${RED}Failed to create system user '$APP_CODE_NAME'. Check if user already exists or if you have sudo privileges.${NC}"
        exit 1
    fi
    sudo mkdir -p "$APP_DIR"
    sudo chown "$APP_CODE_NAME:$APP_CODE_NAME" "$APP_DIR"
    sudo chmod 750 "$APP_DIR" # Secure permissions

    # --- GIT CLONE ---
    color_echo "Cloning repository from $GITHUB_REPO into $APP_DIR..."
    CLONE_CMD="git clone --depth 1 $GITHUB_REPO $APP_DIR" # Shallow clone for speed
    if [[ "$GITHUB_REPO" == "https://"* ]] && [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_PAT" ]; then
        # For private HTTPS repositories
        AUTH_REPO_URL=$(echo "$GITHUB_REPO" | sed "s|https://|https://$GITHUB_USERNAME:$GITHUB_PAT@|")
        CLONE_CMD="git clone --depth 1 $AUTH_REPO_URL $APP_DIR"
    fi

    # Execute clone as the app user to ensure correct permissions from the start
    # Redirect stderr to stdout to capture git errors, then check status
    clone_output=$(sudo -u "$APP_CODE_NAME" bash -c "$CLONE_CMD" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to clone repository:${NC}"
        echo "$clone_output"
        echo -e "${RED}Check repository URL, permissions, or network connectivity.${NC}"
        exit 1 # Cleanup will be triggered
    fi
    color_echo "Repository cloned successfully."

    # --- REQUIREMENTS FILE HANDLING (NEW) ---
    REQUIREMENTS_FILE_NAME="requirements.txt"
    SKIP_REQUIREMENTS_INSTALL=false
    ESSENTIAL_DEPS="uvloop httptools" # Always install these for uvicorn

    # Check if default requirements.txt exists in the cloned repo
    # Running test -f as the app user inside the app directory
    if ! sudo -u "$APP_CODE_NAME" bash -c "cd '$APP_DIR' && test -f '$REQUIREMENTS_FILE_NAME'"; then
        color_echo "File '$REQUIREMENTS_FILE_NAME' not found in '$APP_DIR'."

        if [ "$INSTALLATION_MODE" = "Easy" ]; then
            color_echo "Easy Mode: Skipping project-specific dependencies as '$REQUIREMENTS_FILE_NAME' is missing."
            SKIP_REQUIREMENTS_INSTALL=true
        else # Advanced mode, ask the user
            while true; do
                read -p "Skip project dependencies, specify file, or abort? (Skip/File/Abort) [S/f/a, default: A]: " req_action
                req_action_lower=$(echo "${req_action:-A}" | tr '[:upper:]' '[:lower:]') # Default to Abort

                if [[ "$req_action_lower" == "s" || "$req_action_lower" == "skip" ]]; then
                    SKIP_REQUIREMENTS_INSTALL=true
                    color_echo "Skipping project-specific dependency installation."
                    break
                elif [[ "$req_action_lower" == "f" || "$req_action_lower" == "file" ]]; then
                    read -p "Enter the name of your requirements file (e.g., requirements-dev.txt): " new_req_file
                    if [ -z "$new_req_file" ]; then
                        echo -e "${RED}File name cannot be empty.${NC}"
                        continue
                    fi
                    if sudo -u "$APP_CODE_NAME" bash -c "cd '$APP_DIR' && test -f '$new_req_file'"; then
                        REQUIREMENTS_FILE_NAME="$new_req_file"
                        color_echo "Using '$REQUIREMENTS_FILE_NAME' for project dependencies."
                        break
                    else
                        color_echo "${RED}File '$new_req_file' not found in '$APP_DIR'. Please try again.${NC}"
                    fi
                elif [[ "$req_action_lower" == "a" || "$req_action_lower" == "abort" ]]; then
                    echo -e "${RED}Aborting installation due to requirements file issue.${NC}"
                    exit 1
                else
                    echo -e "${RED}Invalid choice. Please enter 'S' (Skip), 'F' (File), or 'A' (Abort).${NC}"
                fi
            done
        fi
    fi

    # --- PYTHON VIRTUAL ENVIRONMENT AND DEPENDENCIES ---
    execute_quietly "Creating Python virtual environment in $APP_DIR/venv" sudo -u "$APP_CODE_NAME" bash -c "cd '$APP_DIR' && python3 -m venv venv"
    color_echo "Virtual environment created."

    color_echo "Preparing to install Python dependencies..."

    # --- PIP INSTALLATION ---
    PIP_INSTALL_CMD_BASE="source venv/bin/activate && pip install --no-cache-dir -q"

    ESSENTIAL_DEPS="uvloop httptools"

    FULL_PIP_INSTALL_STRING=""
    if [ "$SKIP_REQUIREMENTS_INSTALL" = "false" ]; then
        color_echo "Project dependencies will be installed from '$REQUIREMENTS_FILE_NAME' along with essential packages."
        FULL_PIP_INSTALL_STRING="${PIP_INSTALL_CMD_BASE} -r '$REQUIREMENTS_FILE_NAME' && ${PIP_INSTALL_CMD_BASE} ${ESSENTIAL_DEPS}"
    else
        # This message is fine too
        color_echo "Skipping project-specific dependencies. Installing only essential packages: $ESSENTIAL_DEPS."
        FULL_PIP_INSTALL_STRING="${PIP_INSTALL_CMD_BASE} ${ESSENTIAL_DEPS}"
    fi

    color_echo "Installing Python dependencies (using pip -q, this may take a moment)..."
    local pip_command_to_execute="cd '$APP_DIR' && $FULL_PIP_INSTALL_STRING"
    local pip_output
    # Capture combined output to check if pip -q still produced anything (e.g., warnings)
    pip_output=$(sudo -u "$APP_CODE_NAME" bash -c "$pip_command_to_execute" 2>&1)
    local pip_status=$?

    if [ $pip_status -ne 0 ]; then
        echo -e "${RED}Failed to install Python dependencies.${NC}"
        echo -e "${YELLOW}Command executed: sudo -u \"$APP_CODE_NAME\" bash -c \"$pip_command_to_execute\"${NC}"
        echo -e "${YELLOW}Output from pip (even with -q, errors/warnings might appear):${NC}"
        echo "$pip_output" # Show the captured output from pip
        echo -e "${YELLOW}Consider running the pip commands manually without '-q' inside the venv for more details.${NC}"
        exit 1
    fi

    # Check if pip_output has anything significant. pip -q should be silent on success.
    if [ -z "$pip_output" ] || [[ "$pip_output" =~ ^WARNING:\ You\ are\ using\ pip\ version.* ]]; then # Ignore common pip version warning
         color_echo "Python dependencies installed successfully."
    else
         color_echo "Python dependencies installed. pip produced some output (e.g., warnings):"
         echo -e "${NC}$pip_output${NC}" # Show other minor warnings if any, reset color
    fi
    
    # Permissions for venv are usually fine if created by the user, but chown doesn't hurt.
    sudo chown -R "$APP_CODE_NAME:$APP_CODE_NAME" "$APP_DIR/venv" 

    # --- SYSTEMD SERVICE ---
    color_echo "Creating systemd service file: /etc/systemd/system/$APP_CODE_NAME.service"
    # Ensure APP_DIR is used in paths
    if ! sudo tee "/etc/systemd/system/$APP_CODE_NAME.service" > /dev/null << EOL
[Unit]
Description=$APP_NICE_NAME API Powered by FastAPI
After=network.target
Wants=network-online.target
Documentation=$GITHUB_REPO

[Service]
Type=simple
Restart=always
RestartSec=15
User=$APP_CODE_NAME
Group=$APP_CODE_NAME
Environment="PATH=$APP_DIR/venv/bin:\$PATH"
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/uvicorn \\
    --host 127.0.0.1 \\
    --port $APP_PORT \\
    --loop uvloop \\
    --http httptools \\
    --proxy-headers \\
    --forwarded-allow-ips='*' \\
    --log-level warning \\
    --access-log \\
    --use-colors \\
    --workers $NUM_WORKERS \\
    --limit-concurrency $CONCURRENCY_LIMIT \\
    --backlog $BACKLOG_SIZE \\
    $UVICORN_APP_MODULE

# Security enhancements
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
ProtectHome=read-only # Changed from true to allow reading files in home if necessary, though APP_DIR is /var/www
# Consider ProtectHome=true if app has no reason to read user homes.
# Or ProtectHome=yes (alias for true)
# If app needs write access to its own APP_DIR (e.g. for logs, uploads within APP_DIR),
# ReadWritePaths=$APP_DIR can be added. WorkingDirectory grants some implicit access.
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

# Resource management
Nice=$NICE_VALUE
CPUQuota=$CPU_QUOTA
MemoryMax=$MEMORY_MAX

# Logging
StandardOutput=journal
StandardError=journal

# Graceful shutdown
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOL
    then
        echo -e "${RED}Failed to create systemd service file.${NC}"
        exit 1
    fi
    color_echo "Systemd service file created."

    sudo systemctl daemon-reload
    color_echo "Enabling service $APP_CODE_NAME..."
    sudo systemctl enable "$APP_CODE_NAME.service"
    color_echo "Starting service $APP_CODE_NAME..."
    if ! sudo systemctl start "$APP_CODE_NAME.service"; then
        echo -e "${RED}Failed to start $APP_CODE_NAME service.${NC}"
        echo "Check service status with: sudo systemctl status $APP_CODE_NAME.service"
        echo "Check service logs with: sudo journalctl -u $APP_CODE_NAME -e"
        exit 1
    fi
    color_echo "Service $APP_CODE_NAME started successfully."

    # --- NGINX CONFIGURATION ---
    color_echo "Creating Nginx configuration: /etc/nginx/sites-available/$APP_CODE_NAME"
    if ! sudo tee "/etc/nginx/sites-available/$APP_CODE_NAME" > /dev/null << EOL
server {
    listen 80;
    server_name $DOMAIN_NAME;

    # Optional: Redirect www to non-www (or vice-versa)
    # if (\$host = www.$DOMAIN_NAME) {
    #     return 301 http://$DOMAIN_NAME\$request_uri;
    # }

    # For Certbot (Let's Encrypt)
    location /.well-known/acme-challenge/ {
        root /var/www/html; # Or a dedicated acme challenge directory
        allow all;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';" always;
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always; # Enable HSTS carefully after SSL is confirmed working

    # . files protection
    location ~ /\.(?!well-known) { # Allow .well-known for certbot etc.
        deny all;
    }

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host; # Common practice
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade; # For WebSockets if needed
        proxy_set_header Connection "upgrade";   # For WebSockets if needed
        # If not using WebSockets, Connection can be "keep-alive" or just ""
        # proxy_set_header Connection "keep-alive";

        proxy_redirect off;
        proxy_buffering on; # Can be off for streaming responses

        # Timeouts
        proxy_connect_timeout 75s;
        proxy_send_timeout 300s;  # Increased for long uploads/requests
        proxy_read_timeout 300s;  # Increased for long responses
        send_timeout 300s;

        # Gzip compression
        gzip on;
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level $NGINX_GZIP_COMP_LEVEL;
        gzip_min_length 256; # Don't gzip very small files
        gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
    }

    # Static files caching (optional, if your FastAPI app serves static files through Nginx)
    # location /static/ {
    #     alias $APP_DIR/static/; # Adjust path to your static files
    #     expires 30d;
    #     add_header Cache-Control "public, no-transform";
    # }

    # Deny access to sensitive files if any are directly in webroot (not typical for proxy setup)
    # location ~* /(\.git|\.hg|\.svn)/ {
    #     deny all;
    # }
}
EOL
    then
        echo -e "${RED}Failed to create Nginx configuration.${NC}"
        exit 1
    fi
    color_echo "Nginx configuration created."

    # Enable Nginx site
    if [ -L "/etc/nginx/sites-enabled/$APP_CODE_NAME" ]; then
        color_echo "Nginx site symlink already exists. Overwriting."
        sudo rm -f "/etc/nginx/sites-enabled/$APP_CODE_NAME" # Remove if exists to avoid ln error
    fi
    sudo ln -s "/etc/nginx/sites-available/$APP_CODE_NAME" "/etc/nginx/sites-enabled/"
    color_echo "Nginx site enabled."

    color_echo "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        echo -e "${RED}Nginx configuration test failed. Check errors above.${NC}"
        echo "The problematic Nginx config file is likely /etc/nginx/sites-available/$APP_CODE_NAME"
        exit 1
    fi
    color_echo "Nginx configuration test successful."

    color_echo "Restarting Nginx..."
    if ! sudo systemctl restart nginx; then
        echo -e "${RED}Failed to restart Nginx.${NC}"
        exit 1
    fi
    color_echo "Nginx restarted successfully."

    # Best effort to get a public IP. User might need to verify.
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="YOUR_SERVER_IP" # Fallback placeholder
    fi

    # --- FINAL MESSAGE ---
    echo -e "${GREEN}--------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}Installation complete! Your FastAPI app '$APP_NICE_NAME' should be accessible soon.${NC}"
    echo -e "  System Name:    ${YELLOW}$APP_CODE_NAME${NC}"
    echo -e "  Domain:         ${YELLOW}http://$DOMAIN_NAME${NC} (and potentially https://$DOMAIN_NAME after SSL setup)"
    echo -e "  App Directory:  ${YELLOW}$APP_DIR${NC}"
    echo -e "  Service Status: ${YELLOW}sudo systemctl status $APP_CODE_NAME.service${NC}"
    echo -e "  Service Logs:   ${YELLOW}sudo journalctl -u $APP_CODE_NAME -f -e${NC}"
    if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "YOUR_SERVER_IP" ]; then # Only show server IP if determined
        echo -e "  Server IP:      ${YELLOW}$SERVER_IP${NC} (use this for your DNS A record if setting up DNS manually)"
    fi
    echo -e "${GREEN}--------------------------------------------------------------------------${NC}"

    if [ "$INSTALLATION_MODE" = "Easy" ]; then
        echo -e "${YELLOW}Next Steps for Domain and SSL (Easy Mode Guidance):${NC}"
        echo "1.  **Point your domain to the server:**"
        if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "YOUR_SERVER_IP" ]; then
            echo "    - Go to your domain registrar or DNS provider."
            echo "    - Create an 'A' record for '$DOMAIN_NAME' (and 'www.$DOMAIN_NAME' if desired) pointing to this server's IP address: $SERVER_IP"
            echo "    - DNS propagation can take some time (minutes to hours)."
        else
            echo "    - Go to your domain registrar or DNS provider."
            echo "    - Determine this server's public IP address."
            echo "    - Create an 'A' record for '$DOMAIN_NAME' (and 'www.$DOMAIN_NAME' if desired) pointing to this server's IP address."
            echo "    - DNS propagation can take some time (minutes to hours)."
        fi
        echo
        echo "2.  **Choose an SSL/HTTPS method (to secure your site with https://):**"
        echo "    a) **Using Let's Encrypt with Certbot (Installed during this setup):**"
        echo -e "       - Once DNS has propagated, run the following command: ${GREEN}sudo certbot --nginx -d $DOMAIN_NAME${NC}"
        echo -e "       - If you also want 'www.$DOMAIN_NAME', include it: ${GREEN}sudo certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME${NC}"
        echo "       - This installs a free SSL certificate directly on your server and configures Nginx for HTTPS."
        echo
        echo "    b) **Using Cloudflare (Flexible SSL - Easy Setup, Some Security Caveats):**"
        echo "       - Sign up for a free Cloudflare account at cloudflare.com."
        echo "       - Add your domain '$DOMAIN_NAME' to Cloudflare."
        echo "       - Cloudflare will provide you with new nameservers. Update your domain's nameservers at your registrar to point to Cloudflare's nameservers."
        echo "       - In your Cloudflare dashboard for '$DOMAIN_NAME', navigate to 'SSL/TLS' -> 'Overview'."
        echo "       - Select the **'Flexible'** SSL/TLS encryption mode."
        echo -e "       - ${YELLOW}Important Note:${NC} Flexible SSL means traffic between users and Cloudflare is encrypted, but traffic between Cloudflare and your server ($DOMAIN_NAME) remains HTTP (unencrypted)."
        echo "         This is easier to set up but less secure than Cloudflare's 'Full' or 'Full (Strict)' modes (which would require a certificate on your server, like one from Certbot)."
        echo
        echo "3.  **Test your application:**"
        echo "    - After DNS propagation and SSL setup (if chosen), visit http://$DOMAIN_NAME or https://$DOMAIN_NAME in your browser."
        echo
        echo "4.  **Monitor your application:**"
        echo "    - Use the service status and log commands provided above."

    else # Advanced Mode
        echo -e "${YELLOW}Next Steps (Advanced Mode):${NC}"
        echo -e "- Ensure your domain '$DOMAIN_NAME' is correctly pointed to this server's IP address."
        echo -e "- If using SSL (highly recommended), configure it for Nginx (e.g., using your own certificates, or a reverse proxy)."
        echo -e "- To use Let's Encrypt/Certbot (not installed by this script in Advanced mode):"
        echo -e "    Install it: ${GREEN}sudo apt update && sudo apt install certbot python3-certbot-nginx${NC}"
        echo -e "    Then run:   ${GREEN}sudo certbot --nginx -d $DOMAIN_NAME${NC}"
        echo -e "- Test your application by visiting http://$DOMAIN_NAME (or https://$DOMAIN_NAME if SSL is configured)."
        echo -e "- Monitor your application logs and server resources using the commands shown above."
    fi
    echo # Extra newline for spacing

    # Display Nice values of other user-installed apps (simple version)
    color_echo "Nice values of user processes (excluding root):"
    ps -eo nice,user:20,comm --sort=nice | awk '$2 != "root" && $2 != "USER" && NR > 1' | uniq | tail -n 20

    # Mark install as successful BEFORE clearing APP_CODE_NAME for the EXIT trap
    ACTION_COMPLETED_APP_CLEARED="true"
    APP_CODE_NAME_SUCCESSFUL="$APP_CODE_NAME"
    APP_CODE_NAME=""
}

main
exit_status=$?
if [ $exit_status -eq 0 ] && [ -n "${APP_CODE_NAME_SUCCESSFUL:-}" ]; then
    echo -e "${GREEN}Deployment of '${APP_CODE_NAME_SUCCESSFUL}' was successful.${NC}"
else
    echo -e "${RED}Script encountered an error or was aborted.${NC}"
fi
exit $exit_status