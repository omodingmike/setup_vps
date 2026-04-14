# 🚀 VPS Setup & Deployment Guide

This repository provides automation scripts to provision a fresh Ubuntu/Debian VPS and deploy both frontend and backend services using Docker.

---

## ⚠️ Prerequisites

Ensure you have the following before proceeding:

- A **fresh, unmodified VPS** running Ubuntu or Debian
- **Root SSH access** to the server
- Your **local SSH public key** (you’ll be prompted during setup)

---

## 🧱 Step 1: Initial Server Setup

Run the following command as `root` to download and execute the setup script:

```bash
curl -o ~/setup.sh https://raw.githubusercontent.com/omodingmike/setup_vps/main/setup.sh \
&& chmod +x ~/setup.sh \
&& ./setup.sh
```

### What this script does

- Configures the base system
- Sets up SSH access
- Installs required dependencies (e.g., Docker)
- Prepares the server for deployment

---

## 🚀 Step 2: Application Deployment

Once the server setup is complete, run the deployment script:

```bash
curl -o ~/deploy.sh https://raw.githubusercontent.com/omodingmike/setup_vps/main/deploy.sh \
&& chmod +x ~/deploy.sh \
&& ./deploy.sh
```

## ➕ Step 3: Add Additional Repositories

If you need to deploy additional applications or services alongside your main deployment on the same server, use the add repository script:

```bash
curl -o ~/add_repo.sh [https://raw.githubusercontent.com/omodingmike/setup_vps/main/add_repo.sh](https://raw.githubusercontent.com/omodingmike/setup_vps/main/add_repo.sh) \
&& chmod +x ~/add_repo.sh \
&& ./add_repo.sh


### What this script does

- Pulls application code and images
- Builds and starts Docker containers
- Initializes frontend and backend services

---

## ✅ Notes

- Run both steps **as `root`** unless your setup script configures a non-root user
- Ensure required ports are open (e.g., `80`, `443`, `3000`)
- If using a firewall (`ufw`), verify rules after setup

---

## 📌 Summary

1. Run setup script → prepares VPS
2. Run deploy script → launches application

---

## 🔧 Optional Improvements

- Domain + SSL setup (Let’s Encrypt)
- CI/CD pipeline (GitHub Actions)
- Multi-tenancy production optimizations
- Monitoring (Prometheus, Grafana)