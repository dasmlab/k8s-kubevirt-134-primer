#!/bin/bash
# Simple script to quicken up my commits, commits a ll things, and pushes to main with a message
#
# Usage: ./bumpme.sh "<your commit message"

git add -A .
git commit -m "$1"
git push origin main
