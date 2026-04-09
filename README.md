# 🚀 VPS Setup & Deployment Guide

This repository contains the automation scripts required to provision a brand-new Ubuntu/Debian Virtual Private Server (VPS) and deploy the SmartDuuka frontend and backend applications using Docker.

## ⚠️ Prerequisites
* A fresh, unmodified VPS running Ubuntu or Debian.
* `root` SSH access to the server.
* Your local SSH Public Key (you will be prompted to paste this during setup).

---

## Step 1: Initial Server Setup
Run the following command as `root` to download and execute the setup script:

```bash
curl -o ~/setup.sh [https://raw.githubusercontent.com/omodingmike/setup_vps/main/setup.sh](https://raw.githubusercontent.com/omodingmike/setup_vps/main/setup.sh) && chmod +x ~/setup.sh && ./setup.sh