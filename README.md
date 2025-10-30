# Collaborative Calendar Management Platform

> A secure, multi-user web application for managing church events with admin approval workflow

[![Built with Vite](https://img.shields.io/badge/Built%20with-Vite-646CFF?style=flat&logo=vite)](https://vitejs.dev/)
[![React](https://img.shields.io/badge/React-18.3-61DAFB?style=flat&logo=react)](https://reactjs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.8-3178C6?style=flat&logo=typescript)](https://www.typescriptlang.org/)
[![Supabase](https://img.shields.io/badge/Supabase-Backend-3ECF8E?style=flat&logo=supabase)](https://supabase.com/)

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Tech Stack](#tech-stack)
- [Getting Started](#getting-started)
- [User Roles](#user-roles)
- [Event Lifecycle](#event-lifecycle)
- [Database Schema](#database-schema)
- [Seeding Initial Users](#seeding-initial-users)
- [Deployment](#deployment)
- [Project Structure](#project-structure)
- [API Documentation](#api-documentation)

## Overview

This platform enables ministry leaders at Addis Lidet Ethiopian Medhanie Alem Church (Maryland) to collaboratively manage events across multiple rooms. All events require admin approval before being published to the public calendar website.

**Key Benefits:**
- Centralized event management
- Multi-room scheduling with conflict prevention
- Approval workflow for quality control
- Public calendar for community visibility
- Export capabilities (ICS format)

## Features

### For Contributors
- 📅 Create and edit event drafts
- 🔄 Submit events for admin review
- 👀 View own events and published events
- 📱 Responsive mobile interface

### For Admins
- ✅ Approve/reject event submissions
- 📊 Comprehensive admin dashboard
- 👥 User management (view, import from CSV)
- 🏢 Room management (create, edit, delete)
- 📢 Publish approved events

### Public Features
- 🌐 Beautiful public calendar view
- 📥 Export calendar to ICS
- ⛪ Church information display
- 📱 Fully responsive design

## Tech Stack

| Component | Technology |
|-----------|-----------|
| **Frontend** | React 18.3, TypeScript, Vite |
| **UI Components** | shadcn/ui, Radix UI |
| **Styling** | Tailwind CSS |
| **Backend** | Supabase (Auth, Database, RLS) |
| **Database** | PostgreSQL (via Supabase) |
| **State Management** | TanStack Query (React Query) |
| **Routing** | React Router v6 |
| **Date Handling** | date-fns |
| **Form Validation** | Zod, React Hook Form |

## Getting Started

### Prerequisites

- Node.js 18+ and npm
- Supabase account
- Git

### Installation

1. **Clone the repository**
   ```bash
   git clone <your-repo-url>
   cd approval-agenda
   ```

2. **Install dependencies**
   ```bash
   npm install
   ```

3. **Set up environment variables**

   Create a `.env` file in the project root:
   ```env
   VITE_SUPABASE_URL=your_supabase_project_url
   VITE_SUPABASE_ANON_KEY=your_supabase_anon_key
   SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
   ```

4. **Apply database migrations**

   Install Supabase CLI:
   ```bash
   npm install -g supabase
   ```

   Link to your project:
   ```bash
   supabase link --project-ref your-project-ref
   ```

   Push migrations:
   ```bash
   supabase db push
   ```

5. **Seed initial users (optional)**

   Place the `ALIC MD Leaders Name(Ministry leaders).csv` file in the project root, then:
   ```bash
   npm run seed:users
   ```

   See [Seeding Initial Users](#seeding-initial-users) for details.

6. **Start development server**
   ```bash
   npm run dev
   ```

7. **Open your browser**

   Navigate to `http://localhost:5173`

## User Roles

The platform has two primary roles:

### Contributor
- Create, edit, and submit events for review
- View own events and published events
- Cannot approve or publish events

### Admin
- All contributor permissions
- Approve, reject, or publish events
- Manage rooms (create, edit, delete)
- View all users and their roles
- Access admin dashboard

## Event Lifecycle

Events flow through the following states:

```
draft → pending_review → approved → published
           ↓
        rejected
```

### Status Definitions

| Status | Description | Who Can Set |
|--------|-------------|-------------|
| **draft** | Initial state, work in progress | Contributor |
| **pending_review** | Submitted for admin approval | Contributor |
| **approved** | Admin approved, ready to publish | Admin |
| **rejected** | Admin rejected submission | Admin |
| **published** | Live on public calendar | Admin |

### Conflict Prevention

The system prevents overlapping events in the same room using a PostgreSQL exclusion constraint:

```sql
EXCLUDE USING gist (
  room_id WITH =,
  tstzrange(starts_at, ends_at, '[)') WITH &&
)
WHERE (status IN ('approved', 'published'))
```

This ensures no double-booking of rooms for approved/published events.

## Database Schema

### Tables

#### `profiles`
```sql
- id (uuid, FK to auth.users)
- full_name (text)
- email (text)
- phone_number (text, nullable)
- created_at (timestamptz)
- updated_at (timestamptz)
```

#### `user_roles`
```sql
- id (uuid)
- user_id (uuid, FK to auth.users)
- role (enum: 'admin' | 'contributor')
- created_at (timestamptz)
```

#### `rooms`
```sql
- id (uuid)
- name (text, unique)
- description (text, nullable)
- color (text)
- is_active (boolean)
- created_at (timestamptz)
- updated_at (timestamptz)
```

#### `events`
```sql
- id (uuid)
- room_id (uuid, FK to rooms)
- title (text)
- description (text, nullable)
- starts_at (timestamptz)
- ends_at (timestamptz)
- status (enum: 'draft' | 'pending_review' | 'approved' | 'rejected' | 'published')
- created_by (uuid, FK to auth.users)
- reviewer_id (uuid, FK to auth.users, nullable)
- reviewer_notes (text, nullable)
- created_at (timestamptz)
- updated_at (timestamptz)
```

### Row-Level Security (RLS)

All tables have RLS enabled with appropriate policies:

- **Profiles**: Users can view all profiles, update own profile
- **User Roles**: Admins view all, users view own, admins manage all
- **Rooms**: All authenticated users view active rooms, admins manage all
- **Events**: Complex policies based on status and ownership

## Seeding Initial Users

The platform includes a script to import users from CSV:

```bash
npm run seed:users
```

### CSV Format

The CSV should have these columns:
```
Ministry Name,Leader's Name,Email,phone Number
```

### What the Script Does

1. Reads the CSV file
2. Creates Supabase Auth users
3. Creates profile entries
4. Assigns roles (admin or contributor)
5. Generates temporary passwords
6. Saves credentials to `user-credentials.json`

**Important:**
- Send credentials securely to users
- Delete `user-credentials.json` after distribution
- Users should change passwords on first login

See [scripts/README.md](scripts/README.md) for detailed documentation.

## Deployment

### Deploy to Vercel

1. **Push code to GitHub**

2. **Connect Vercel**
   - Go to [vercel.com](https://vercel.com)
   - Import your repository
   - Configure environment variables

3. **Set environment variables in Vercel**
   ```
   VITE_SUPABASE_URL=...
   VITE_SUPABASE_ANON_KEY=...
   ```

4. **Deploy**

   Vercel will auto-deploy on push to main branch.

### Database Migrations

Ensure migrations are applied in Supabase:
```bash
supabase db push
```

## Project Structure

```
approval-agenda/
├── src/
│   ├── components/       # Reusable UI components
│   │   ├── calendar/    # Calendar-specific components
│   │   ├── layout/      # Layout components
│   │   └── ui/          # shadcn/ui components
│   ├── contexts/        # React contexts (Auth, etc.)
│   ├── hooks/           # Custom React hooks
│   ├── integrations/    # External service integrations
│   │   └── supabase/    # Supabase client configuration
│   ├── lib/             # Utility functions
│   ├── pages/           # Route pages
│   │   ├── Admin.tsx
│   │   ├── Auth.tsx
│   │   ├── Dashboard.tsx
│   │   ├── PublicCalendar.tsx
│   │   ├── Rooms.tsx
│   │   └── Users.tsx
│   ├── App.tsx          # Main app component
│   └── main.tsx         # Entry point
├── supabase/
│   └── migrations/      # Database migrations
├── scripts/             # Utility scripts
│   ├── seed-users.ts
│   └── README.md
├── public/              # Static assets
└── package.json
```

## API Documentation

### Key Endpoints (via Supabase Client)

#### Events

```typescript
// Get all published events
const { data } = await supabase
  .from("events")
  .select("*, rooms(id, name, color)")
  .eq("status", "published");

// Create event
const { data } = await supabase
  .from("events")
  .insert({
    room_id,
    title,
    description,
    starts_at,
    ends_at,
    created_by
  });

// Update event status
const { data } = await supabase
  .from("events")
  .update({ status: "approved", reviewer_id })
  .eq("id", eventId);
```

#### Rooms

```typescript
// Get active rooms
const { data } = await supabase
  .from("rooms")
  .select("*")
  .eq("is_active", true);

// Create room
const { data } = await supabase
  .from("rooms")
  .insert({ name, description, color, is_active });
```

### Public Calendar Export

The public calendar page includes ICS export functionality:

**Download URL Pattern:**
```
/public
Click "Export Calendar" button → Downloads ICS file
```

## Development Scripts

| Script | Description |
|--------|-------------|
| `npm run dev` | Start development server |
| `npm run build` | Build for production |
| `npm run preview` | Preview production build |
| `npm run lint` | Run ESLint |
| `npm run seed:users` | Import users from CSV |

## Contributing

1. Create a feature branch
2. Make your changes
3. Test thoroughly
4. Submit a pull request

## Support

For issues or questions:
- Check existing GitHub issues
- Create a new issue with detailed description
- Contact the IT team at info@addislidetchurch.org

## License

© 2025 Addis Lidet Ethiopian Medhanie Alem Church. All rights reserved.

---

**Built with ❤️ for the ALIC MD community**
