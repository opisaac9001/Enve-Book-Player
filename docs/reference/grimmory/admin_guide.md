# Grimmory Admin & Server Management API Guide

This guide details the endpoints required for server administration, user management, and initial setup for the Grimmory application. These endpoints are primarily consumed by the web dashboard or admin clients.

> **Note:** Most endpoints below require the authenticated user to possess the `ADMIN` role. Pass the JWT token via the `Authorization: Bearer <TOKEN>` header.

--- 

## 🛠️ 1. Initial Setup
Used during the very first run of the server to provision the admin account.
* **Get Setup Status**: `GET /api/v1/setup/status`
  * Returns whether the server has already been set up.
* **Setup First User**: `POST /api/v1/setup`
  * Provisions the initial admin account. Will reject (`403`) if setup is already complete.

---

## 👥 2. User Management
Endpoints under `/api/v1/users` and `/api/v1/auth`.

* **Create / Register User**: `POST /api/v1/auth/register`
  * *Requires Admin*.
  * Body: `{"username": "...", "password": "...", "email": "..."}`
* **List All Users**: `GET /api/v1/users`
  * *Requires Admin*.
* **Get Specific User**: `GET /api/v1/users/{id}`
* **Update User Info / Roles**: `PUT /api/v1/users/{id}`
  * *Requires Admin*.
  * Body: Includes assigned roles, emails, and permissions.
* **Delete User**: `DELETE /api/v1/users/{id}`
  * *Requires Admin*.
* **Change Own Password**: `PUT /api/v1/users/change-password`
* **Force Change User Password**: `PUT /api/v1/users/change-user-password`
  * *Requires Admin*. 

---

## 📚 3. Library Configuration
Endpoints for managing media directories under `/api/v1/libraries`.

* **Create Library**: `POST /api/v1/libraries`
  * *Requires Admin or Library Manager*.
  * Body: `CreateLibraryRequest` detailing the root folder paths to monitor.
* **Update Library**: `PUT /api/v1/libraries/{libraryId}`
* **Delete Library**: `DELETE /api/v1/libraries/{libraryId}`
* **Trigger Library Rescan**: `PUT /api/v1/libraries/{libraryId}/refresh`
  * Instructs the server to check for new books/audiobooks on disk.
* **Dry-Run Scan**: `POST /api/v1/libraries/scan`
  * Verifies paths and returns the count of processable files before actually committing the library.
* **Check Library Health**: `GET /api/v1/libraries/health`
  * Checks physical disk accessibility for all configured libraries.

---

## ⚙️ 4. Server Tasks & Background Jobs
Endpoints for viewing and triggering background jobs (like Metadata Syncing). `/api/v1/tasks`

* **List Available Tasks**: `GET /api/v1/tasks`
* **Trigger a Task Manually**: `POST /api/v1/tasks/start`
  * Body: `{"type": "METADATA_SYNC"}` etc.
* **Cancel Running Task**: `DELETE /api/v1/tasks/{taskId}/cancel`
* **View Task History**: `GET /api/v1/tasks/last`
* **Update Task Cron Schedule**: `PATCH /api/v1/tasks/{taskType}/cron`
  * Updates the automatic scheduling configuration for background jobs.

---

## 🎛️ 5. Global App Settings
* **Get Settings**: `GET /api/v1/settings`
  * Returns an AppSettings object containing global preferences (OIDC, Remote Auth, Mail settings).
* **Update Settings**: `PUT /api/v1/settings`
  * Body: A list of `SettingRequest` objects: `[{"name": "SETTING_KEY", "value": "new_value"}]`
* **Test OIDC Connection**: `POST /api/v1/settings/oidc/test`
  * Directly tests an OpenID Connect configuration without saving it globally.
