# Spring Petclinic on AWS — Deployment Guide

> **Owner:** ukumar | **Project:** 2026_internship_hyd | **Region:** eu-north-1 (Stockholm)

---

## Overview

This guide covers two bash scripts that automate the full lifecycle of deploying the Spring Petclinic application on AWS — from infrastructure provisioning to cleanup. The scripts use the AWS CLI and Docker to create a private ECR repository, push a container image, and run it on an EC2 instance.

---

## Script Files

### 01_setup_infra.sh — Infrastructure Setup

The main deployment script. It provisions all required AWS resources and deploys the Spring Petclinic container in **3 steps**:

**Step 1 — Key Pair:**
Checks for an existing EC2 key pair in `eu-north-1`. Creates one if not found and saves it locally as `petclinic-key.pem`.

**Step 2 — Security Group:**
Creates a Security Group inside the existing `petclinic-vpc` with ports `22` (SSH) and `8080` (app) open. Reuses the existing SG if already present from a previous run.

**Step 3 — ECR + EC2:**
Creates a private ECR repository, pulls `uday6395/spring-petclinic` from Docker Hub, pushes it to ECR, then launches a `t3.micro` EC2 instance. The instance installs Docker and runs the container automatically on boot via user-data.

#### Reused Infrastructure (pre-existing, not created by script)

| Resource | ID |
|---|---|
| VPC | `vpc-0c7993409f90d8935` (petclinic-vpc) |
| Subnet | `subnet-0dcb705d65151f109` (eu-north-1a) |
| Internet Gateway | `igw-07e95dec7fa0f0831` |
| Route Table | `rtb-05fcd2b2d56736846` |

#### Created by the script

| Resource | Details |
|---|---|
| EC2 Key Pair | `petclinic-key` |
| Security Group | `petclinic-sg` (ports 22, 8080) |
| ECR Repository | `spring-petclinic` (private) |
| EC2 Instance | `petclinic-ec2` (t3.micro, Amazon Linux 2023) |

---

### 02_cleanup.sh — Resource Cleanup

Safely removes only the resources created by `01_setup_infra.sh`. Pre-existing infrastructure (VPC, subnet, IGW, route table) is left untouched.

#### What it deletes (4 steps)

| Step | Resource | Action |
|---|---|---|
| 1 | EC2 Instance | Terminated (waits for full termination) |
| 2 | Security Group | `petclinic-sg` deleted |
| 3 | ECR Repository | `spring-petclinic` and all images deleted |
| 4 | Key Pair | Deleted from AWS + local `petclinic-key.pem` removed |

#### What it keeps

| Resource | Reason |
|---|---|
| VPC, Subnet, IGW, Route Table | Pre-existing, not created by this project |

---

## Prerequisites

Ensure the following are installed and configured before running the scripts:

- AWS CLI v2 configured with credentials (`aws configure`)
- Docker installed and running
- Bash shell (Linux/macOS or WSL on Windows)
- AWS account `881329308612` with region set to `eu-north-1`

Verify your AWS identity:
```bash
aws sts get-caller-identity
```

Set the region:
```bash
aws configure set region eu-north-1
```

---

## How to Execute

### Step 1 — Deploy Infrastructure

Make the scripts executable and run the setup script:
```bash
chmod +x 01_setup_infra.sh 02_cleanup.sh
./01_setup_infra.sh
```

At the end, the script prints all resource IDs and the app URL:
```
==========================================
 Infrastructure ready!
==========================================
 ECR            : 881329308612.dkr.ecr.eu-north-1.amazonaws.com/spring-petclinic
 Instance ID    : i-xxxxxxxxxxxxxxxxx
 Public IP      : <PUBLIC_IP>

 App URL (wait ~3 min for Docker to start):
   http://<PUBLIC_IP>:8080

 SSH:
   ssh -i petclinic-key.pem ec2-user@<PUBLIC_IP>
==========================================
```

### Step 2 — Verify the Application

Wait approximately **3 minutes** for the EC2 instance to install Docker and start the container, then open the URL in your browser:
```
http://<PUBLIC_IP>:8080
```

To SSH in and verify Docker is running:
```bash
ssh -i petclinic-key.pem ec2-user@<PUBLIC_IP>
sudo docker ps
```

You should see the `spring-petclinic` container listed as `Up`.

### Step 3 — Clean Up

When done, run the cleanup script to remove all created resources:
```bash
./02_cleanup.sh
```

It will show what will be deleted and ask for confirmation:
```
==========================================
 Spring Petclinic — Cleanup
==========================================
 The following resources will be DELETED:
   EC2 Instance  : i-xxxxxxxxxxxxxxxxx
   Security Group: sg-xxxxxxxxxxxxxxxxx
   ECR Repo      : spring-petclinic
   Key Pair      : petclinic-key

 The following will be KEPT (pre-existing):
   VPC           : vpc-0c7993409f90d8935
   Subnet        : subnet-0dcb705d65151f109
   IGW           : igw-07e95dec7fa0f0831
   Route Table   : rtb-05fcd2b2d56736846

Proceed? (yes/no):
```

---

## Tagging Policy

All created resources are tagged according to the Grid Dynamics tagging policy:

| Tag Key | Value | Description |
|---|---|---|
| `Name` | `<resource-name>` | Unique name for the resource |
| `Owner` | `ukumar` | LDAP username of the creator |
| `Project` | `2026_internship_hyd` | Internship project identifier |

---

## Architecture

```
Docker Hub (uday6395/spring-petclinic)
       |
       v  (docker pull + push via local machine)
ECR — private repo: spring-petclinic:latest
       |
       v  (docker pull via EC2 user-data at boot)
EC2 t3.micro (Amazon Linux 2023)
  └── docker run -p 8080:8080 spring-petclinic
             |
             v
     http://<PUBLIC_IP>:8080
```

---

## Notes

- The script saves all resource IDs to `infra_state.env` after a successful run. The cleanup script reads from this file — do not delete it before running cleanup.
- AWS credentials are injected into the EC2 instance via user-data to allow ECR authentication at boot. This is acceptable for lab/internship environments.
- The application takes approximately 3 minutes to become accessible after the instance starts, as Docker and AWS CLI are installed on first boot.
- If the script fails partway through, check for orphaned resources (Security Group, ECR repo) in the AWS Console and delete them manually before rerunning.
