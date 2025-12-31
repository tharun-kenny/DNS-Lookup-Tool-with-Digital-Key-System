#!/bin/bash

echo "Setting up DNS Lookup Tool with Digital Key System..."
echo "====================================================="

# Check dependencies
echo "Checking dependencies..."
for cmd in dig openssl whois; do
    if ! command -v $cmd &> /dev/null; then
        echo "Installing $cmd..."
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo apt-get update && sudo apt-get install -y $cmd
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            brew install $cmd
        fi
    fi
done

# Create project structure
echo "Creating project structure..."
mkdir -p logs keys exports

# Set permissions
echo "Setting permissions..."
chmod +x dns_tool.sh key_manager.sh
chmod 600 config.env 2>/dev/null || true

# Generate initial key if none exists
echo "Generating initial digital key..."
if [ ! -f keys/user_keys.enc ]; then
    ./key_manager.sh --generate
    echo ""
    echo "⚠️  IMPORTANT: Save the key shown above!"
    echo "You'll need it to unlock the system."
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "Quick start:"
echo "1. First, unlock the system: ./key_manager.sh --unlock"
echo "2. Then use the DNS tool: ./dns_tool.sh -d example.com"
echo "3. For full audit: ./dns_tool.sh -d example.com -a"
echo ""
echo "View documentation: cat README.md"
