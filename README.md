# ELMUAZ Core API

The backend engine behind the **ELMUAZ Enterprise Information Management System (EIMS)**. It handles authentication, user roles, task reviews, and automatic notifications.

## What It Does

- **Role Management:** Tailored access for CEOs, Department Heads, Accountants, and Staff.
- **Task Review Flow:** Guides tasks from initial assignment through submission, peer reviews, corrections, and final sign-off.
- **Submission History:** Keeps an audit trail of every review cycle, deliverable link, and feedback note so nothing gets lost.
- **Instant Alerts:** Automatically lets employees know when a submission is approved or needs changes.

## Tech Behind It

- **Runtime:** Node.js & Express with TypeScript
- **Database:** Supabase (PostgreSQL)

## Getting Started Locally

1. **Install packages:**
   ```bash
   npm install
