#!/bin/bash

cd signaling

# Install npm dependencies if not already installed
if [ ! -d "node_modules" ]; then
    echo "Installing npm dependencies..."
    npm install
fi

echo "Starting signaling server..."
npm start
