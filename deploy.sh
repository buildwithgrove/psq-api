#!/bin/bash
set -e

echo "🚀 PSQ API Deployment Script for Vultr"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Update system
echo "📦 Updating system packages..."
apt-get update && apt-get upgrade -y

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo "Cannot detect OS. This script supports Ubuntu and Debian."
    exit 1
fi

# Install Docker
echo "🐳 Installing Docker on $OS $VERSION..."
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add Docker GPG key and repository based on OS
if [ "$OS" = "ubuntu" ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
elif [ "$OS" = "debian" ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
else
    echo "Unsupported OS: $OS. This script supports Ubuntu and Debian."
    exit 1
fi

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Install Docker Compose
echo "🔧 Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Start Docker service
systemctl start docker
systemctl enable docker

# Create application directory
echo "📁 Setting up application directory..."
mkdir -p /opt/psq-api
cd /opt/psq-api

# Clone or update repository
echo "📥 Setting up repository..."
if [ -d ".git" ]; then
    echo "Repository exists, updating..."
    git fetch origin
    git reset --hard origin/main
else
    echo "Cloning repository..."
    git clone https://github.com/buildwithgrove/psq-api.git .
fi

# Create environment file
echo "⚙️ Creating environment configuration..."
cat > .env << EOF
CHAIN_ENV=BETA
NODE_ENV=production
EOF

# Set up Google Cloud credentials
echo "🔑 Setting up Google Cloud credentials..."
echo "Please place your Google Cloud service account JSON file at /opt/psq-api/credentials.json"
echo "You can do this by running: nano /opt/psq-api/credentials.json"
read -p "Press Enter when you've added the credentials file..."

# Build and start services
echo "🏗️ Building and starting services..."
docker-compose up -d --build

# Create systemd service for auto-restart
echo "🔄 Creating systemd service..."
cat > /etc/systemd/system/psq-api.service << EOF
[Unit]
Description=PSQ API Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/psq-api
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable psq-api

# Set up firewall
echo "🔥 Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Create log rotation
echo "📝 Setting up log rotation..."
cat > /etc/logrotate.d/psq-api << EOF
/opt/psq-api/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    notifempty
    create 0644 root root
    postrotate
        docker-compose -f /opt/psq-api/docker-compose.yml restart psq-api
    endscript
}
EOF

echo "✅ Deployment complete!"
echo ""
echo "🌐 Your API should be running at:"
echo "   Health check: http://$(curl -s ifconfig.me)/health"
echo "   API endpoint: http://$(curl -s ifconfig.me)/api"
echo ""
echo "📋 Next steps:"
echo "1. Point your domain (psq-api.grove.city) to this server's IP"
echo "2. Set up SSL certificate (Let's Encrypt recommended)"
echo "3. Monitor logs: docker-compose logs -f"
echo "4. Test the API with the provided curl commands"
echo ""
echo "🔧 Management commands:"
echo "   Start:   systemctl start psq-api"
echo "   Stop:    systemctl stop psq-api"
echo "   Restart: systemctl restart psq-api"
echo "   Logs:    docker-compose logs -f"