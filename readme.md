# FastDeploy: Rapid FastAPI Deployment Script

[![License: GNU](https://img.shields.io/badge/License-GNU-green.svg)](https://opensource.org/licenses/GNU)

One-liner description: A Bash script to quickly deploy FastAPI applications on Debian/Ubuntu servers using Systemd for service management and Nginx as a reverse proxy, with options for easy or advanced configuration.

## 1. Overview

FastDeploy is designed to streamline the deployment of FastAPI applications. It automates common setup tasks, allowing developers to get their Python web applications up and running quickly on a fresh Debian-based Linux server (like Ubuntu). It sets up a dedicated system user, clones your application from GitHub, creates a Python virtual environment, installs dependencies, configures Uvicorn to run your app, sets up a Systemd service for robust process management, and configures Nginx as a reverse proxy.

## 2. Features

*   **FastAPI Focused:** Tailored for deploying FastAPI applications with Uvicorn.
*   **Systemd Integration:** Creates and manages a systemd service for your application, ensuring it runs on boot and restarts on failure.
*   **Nginx Reverse Proxy:** Sets up Nginx to serve your application, handle HTTP requests, and provide a path for SSL termination.
*   **Python Virtual Environment:** Isolates application dependencies in a `venv`.
*   **Git Repository Cloning:** Fetches your application code directly from a GitHub repository (public or private HTTPS/SSH).
*   **Dependency Management:** Installs Python packages from `requirements.txt`.
*   **User and Permission Management:** Creates a dedicated system user for your application for better security.
*   **Easy & Advanced Modes:**
    *   **Easy Mode:** Sensible defaults and automated Certbot installation for quick setup.
    *   **Advanced Mode:** Granular control over all settings for experienced users.
*   **Install & Uninstall:** Cleanly installs and removes all application components.
*   **Automated System Updates:** Optionally updates and upgrades system packages.
*   **Port Management:** Suggests available ports and checks for port conflicts.
*   **Resource Control:** Configurable Systemd `CPUQuota`, `MemoryMax`, and `Nice` values.
*   **Error Handling & Cleanup:** Attempts to revert changes if the script fails.
*   **Colored Output:** User-friendly, color-coded informational messages, warnings, and errors.

## 3. Prerequisites

Before running this script, ensure your server meets the following requirements:

*   **Operating System:** Debian-based Linux (e.g., 22.04 LTS, 24.04 LTS).
*   **User Privileges:** `sudo` access. The script will use `sudo` for system-level operations.
*   **Internet Connection:** Required for downloading packages, cloning repositories, etc.
*   **Git:** Must be installed if not already present (the script can install it if `apt-get` is configured).
*   **Python 3 & python3-venv:** The script will attempt to install `python3-venv`. Python 3 itself should ideally be present.
*   **FastAPI Application:** Your application code must be in a Git repository (GitHub is directly supported for cloning).
    *   It should have a `requirements.txt` file (or a specified alternative) in the repository root.
    *   You need to know the module and instance for Uvicorn (e.g., `main:app`).
*   **(Optional but Recommended) Domain Name:** A registered domain name that you can point to your server's IP address.

## 4. Installation

### Prerequisites
- Git must be installed on your system
- Terminal/command line access
- Sudo privileges for script execution

### Getting the Script

**1. Navigate to your home directory:**
```bash
cd ~
```

**2. Clone the repository and set permissions:**
```bash
git clone https://github.com/hiomkarpatel/FastDeploy.git
cd FastDeploy
chmod +x FastDeploy.sh
```

### Verification
After installation, verify the script is executable:
```bash
ls -la FastDeploy.sh
```
You should see `-rwxr-xr-x` permissions indicating the script is executable.

### Running the Script

**Important:** Always ensure you're in the FastDeploy directory before running the script.

**1. Navigate to the FastDeploy directory:**
```bash
cd ~/FastDeploy
```

**2. Execute the script:**
```bash
sudo ./FastDeploy.sh
```

### Alternative: One-time Setup
If you want to run the script from anywhere, add it to your PATH or create a symbolic link:

```bash
# Option 1: Add to PATH (add this line to your ~/.bashrc or ~/.zshrc)
export PATH="$HOME/FastDeploy:$PATH"

# Option 2: Create symbolic link
sudo ln -s ~/FastDeploy/FastDeploy.sh /usr/local/bin/fastdeploy
```

After either option, you can run:
```bash
sudo fastdeploy
```

### Troubleshooting
- **Permission denied:** Ensure the script has execute permissions with `chmod +x FastDeploy.sh`
- **Command not found:** Verify you're in the correct directory (`~/FastDeploy`)
- **Git not found:** Install Git using your system's package manager

The script is interactive and will guide you through the process. You can abort at any time by pressing Ctrl+C; the script will attempt to clean up any changes made up to that point.

## 5. Usage
### Main Modes: Install / Uninstall

Upon starting, you'll be asked to choose an action:

*   **Install (I):** Deploys a new FastAPI application.
*   **Uninstall (U):** Removes an existing application deployed by this script.

### Installation Modes: Easy / Advanced

If you choose "Install", you'll then select an installation mode:

*   **Easy Mode (E):**
    *   Uses sensible defaults for most Uvicorn, Systemd, and Nginx settings.
    *   Automatically attempts to install `certbot` and `python3-certbot-nginx` for SSL setup.
    *   Ideal for quick deployments or users new to these configurations.
*   **Advanced Mode (A):**
    *   Prompts for every configuration option.
    *   Does *not* automatically install Certbot (you'll need to install it manually if desired).
    *   Suitable for users who need fine-grained control or have specific requirements.

## 6. Configuration Options (During Installation)

The script will prompt for various details. Below is a summary (Advanced mode exposes all; Easy mode defaults many).

### Application Details

*   **App Nice Name:** A human-readable name for the app (e.g., "My Awesome Product API"). Used in Systemd service description.
*   **App Code Name:** A short, unique, system-level name (e.g., `my_cool_api`). Used for user, group, service file, Nginx config, and directory names. (Letters, numbers, `_`, `-`, `.`)
*   **Uvicorn App Module:** Path to your FastAPI app instance (e.g., `main:app`, `myproject.server:api_instance`).

### GitHub Repository

*   **GitHub Repo URL:** HTTPS or SSH URL of your FastAPI application's repository.
*   **GitHub Username (Optional):** For private HTTPS repositories.
*   **GitHub PAT (Optional):** Personal Access Token for private HTTPS repositories (input is hidden). Scope: `repo`.

### Networking

*   **Domain Name:** The domain/subdomain for your app (e.g., `api.example.com`).
*   **App Port:** Internal port Uvicorn listens on (e.g., `8000`, `3456`). Nginx proxies to this. The script will suggest an available random port.

### Uvicorn Settings

*   **Number of Uvicorn Workers:** Recommended: `(2 * CPU_cores) + 1`.
*   **Uvicorn Concurrency Limit:** Max concurrent connections per worker (default: `1000`).
*   **Uvicorn Backlog Size:** Max queued connections if workers are busy (default: `2048`).

### Systemd Service Settings

*   **Nice Value:** CPU scheduling priority (`-20` highest to `19` lowest, default: `0`).
*   **CPUQuota:** CPU usage limit as a percentage of one CPU core (e.g., `80%`, `150%`).
*   **MemoryMax:** Max RAM for the app (e.g., `512M`, `2G`). Default suggested based on total RAM.

### Nginx Settings

*   **Nginx Gzip Compression Level:** `1` (fastest, low compression) to `9` (slowest, high compression). Default: `6`.

## 7. What the Script Does (Installation Process)

During installation, the script performs the following steps:

1.  **System Preparation:**
    *   Updates package lists (`apt-get update`).
    *   (Optional) Upgrades system packages (`apt-get upgrade`).
    *   Installs Nginx if not present.
    *   Ensures Nginx service is enabled and started.
    *   Installs `python3-venv` if not present.
    *   (Easy Mode Only) Installs `certbot` and `python3-certbot-nginx`.
    *   Installs `lsof` for port checking if not present.
2.  **User and Directory Setup:**
    *   Creates a system user and group named after the `APP_CODE_NAME`.
    *   Creates the application directory (e.g., `/var/www/app_code_name`) and sets ownership.
3.  **Application Code:**
    *   Clones the specified Git repository into the application directory.
    *   Handles `requirements.txt`:
        *   If not found, prompts in Advanced mode (skip, specify, abort) or skips in Easy mode.
4.  **Python Environment:**
    *   Creates a Python virtual environment (`venv`) inside the app directory.
    *   Installs essential dependencies (`uvloop`, `httptools`).
    *   Installs project-specific dependencies from `requirements.txt` (if found/specified and not skipped).
5.  **Systemd Service:**
    *   Creates a systemd service file (e.g., `/etc/systemd/system/app_code_name.service`) configured with Uvicorn settings, resource limits, and security options.
    *   Reloads systemd daemon, enables, and starts the new service.
6.  **Nginx Configuration:**
    *   Creates an Nginx site configuration file (e.g., `/etc/nginx/sites-available/app_code_name`).
    *   Configures Nginx as a reverse proxy to the Uvicorn port.
    *   Includes security headers, gzip compression, and a location block for Certbot's ACME challenge.
    *   Enables the site by creating a symlink in `sites-enabled`.
    *   Tests Nginx configuration and restarts/reloads Nginx.
7.  **Final Output:** Displays a summary of the deployment, including domain, service status commands, and next steps.

## 8. Post-Deployment Steps

After the script completes successfully:

### DNS Configuration

*   Point your domain name (e.g., `api.example.com`) to your server's public IP address.
*   Go to your domain registrar or DNS provider and create an 'A' record for your domain (and `www` subdomain if desired) pointing to the server's IP.
*   DNS propagation can take some time (minutes to hours). The script will attempt to display your server's IP.

### SSL/HTTPS Setup

Securing your application with HTTPS is highly recommended.

#### Using Certbot (Recommended for Easy Mode)

If you used **Easy Mode**, `certbot` and its Nginx plugin should be installed.
Once your DNS has propagated:

```bash
sudo certbot --nginx -d your_domain.com
# For multiple domains (e.g., with www):
# sudo certbot --nginx -d your_domain.com -d www.your_domain.com
```

Follow the Certbot prompts. It will obtain a certificate from Let's Encrypt and automatically update your Nginx configuration for HTTPS.

#### Using Cloudflare (Flexible SSL Option)

1.  Add your domain to Cloudflare.
2.  Update your domain's nameservers at your registrar to Cloudflare's.
3.  In Cloudflare dashboard (SSL/TLS -> Overview), set SSL/TLS encryption mode to **Flexible**.
    *   **Note:** "Flexible" encrypts traffic between the user and Cloudflare, but traffic between Cloudflare and your server remains HTTP. For full end-to-end encryption with Cloudflare, use "Full" or "Full (Strict)" and install a certificate on your server (e.g., via Certbot or a Cloudflare Origin Certificate).

#### Manual SSL (Advanced)

If you used **Advanced Mode** (or prefer manual setup):

1.  Install Certbot manually if you wish to use Let's Encrypt:
    ```bash
    sudo apt update
    sudo apt install certbot python3-certbot-nginx
    ```
2.  Then run `sudo certbot --nginx ...` as above.
3.  Alternatively, obtain SSL certificates from another Certificate Authority and configure Nginx manually by editing `/etc/nginx/sites-available/your_app_code_name`.

## 9. Uninstallation

To remove an application deployed by this script:

1.  Run the script: `./fastdeploy.sh`
2.  Choose **Uninstall (U)** at the prompt.
3.  Enter the `APP_CODE_NAME` of the application you wish to remove.
4.  Confirm the uninstallation.

The uninstallation process will:

*   Stop and disable the systemd service.
*   Remove the systemd service file.
*   Remove Nginx site configuration files (available and enabled).
*   Reload Nginx.
*   Delete the system user and group associated with the app.
*   Delete the application directory (e.g., `/var/www/app_code_name`).

## 10. Troubleshooting

*   **Service Fails to Start:**
    *   Check status: `sudo systemctl status your_app_code_name.service`
    *   View logs: `sudo journalctl -u your_app_code_name.service -e -f`
    *   Common issues: Python errors in your app, incorrect `UVICORN_APP_MODULE`, port conflicts not caught earlier.
*   **Nginx Errors:**
    *   Test config: `sudo nginx -t`
    *   Check Nginx error logs: `/var/log/nginx/error.log`
*   **Git Clone Fails:**
    *   Verify repository URL.
    *   For private HTTPS: Ensure correct username and PAT with `repo` scope.
    *   For SSH: Ensure the server's SSH key (for the `app_code_name` user, or globally if you set it up that way) is added to GitHub. The script attempts cloning as the `app_code_name` user.
*   **Port in Use:** The script checks the chosen `APP_PORT` before starting. If it's taken later by another process, the Uvicorn service will fail.
*   **Permission Issues:** While the script sets permissions, review them if your app has trouble reading/writing files. `sudo chown -R your_app_code_name:your_app_code_name /var/www/your_app_code_name` and `sudo chmod -R ug+rwX /var/www/your_app_code_name` (adjust as needed).
*   **Cleanup on Failure:** The script uses `trap` to run a `cleanup` function on `ERR` or `EXIT`. This attempts to undo changes if the script is interrupted or fails. Review the cleanup output.

## 11. Security Considerations

*   **Systemd Sandboxing:** The generated systemd service includes several `Protect` directives (`PrivateTmp=true`, `ProtectSystem=full`, etc.) to enhance security by limiting the app's access to the system. Review and adjust these based on your application's needs. `ProtectHome=read-only` is used; if your app legitimately needs to write to its *own* home (`/var/www/app_code_name`), this should be fine, but if it needs to write elsewhere in `/home`, adjust or use `ReadWritePaths`.
*   **Nginx Security Headers:** The Nginx configuration includes common security headers (X-Frame-Options, X-XSS-Protection, etc.). Review and customize these. HSTS is commented out by default; enable it only after confirming SSL works perfectly.
*   **Principle of Least Privilege:** The application runs as a dedicated, unprivileged system user.
*   **Dependencies:** Keep your application's Python dependencies and system packages updated to patch vulnerabilities.
*   **Firewall:** Ensure your server firewall (e.g., `ufw`) is configured to allow traffic on ports 80 (HTTP) and 443 (HTTPS) and block unnecessary ports. The script does not manage the firewall.
```bash
# Example ufw setup:
sudo ufw allow ssh       # Or your custom SSH port
sudo ufw allow http
sudo ufw allow https
sudo ufw enable
```

## 12. Contributing

Contributions are welcome! If you have suggestions, bug reports, or want to contribute code:

1.  Fork the repository.
2.  Create a new branch (`git checkout -b feature/your-feature-name`).
3.  Make your changes.
4.  Commit your changes (`git commit -am 'Add some feature'`).
5.  Push to the branch (`git push origin feature/your-feature-name`).
6.  Create a new Pull Request.

Please ensure your code follows the existing style and that your changes are well-tested.

## 13. License

This project is licensed under the GNU License - see the [LICENSE](LICENSE.md) file for details.