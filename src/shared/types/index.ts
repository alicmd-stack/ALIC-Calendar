/**
 * Shared types used across all modules
 */

// Re-export database types
export type {
  Database,
  Tables,
  TablesInsert,
  TablesUpdate,
  Enums,
  Json,
} from "@/integrations/supabase/types";

// Common entity types
export interface BaseEntity {
  id: string;
  created_at: string;
  updated_at: string;
}

// Pagination types
export interface PaginationParams {
  page: number;
  limit: number;
}

export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}

// API response types
export interface ApiResponse<T> {
  data: T | null;
  error: Error | null;
}

export interface ApiListResponse<T> {
  data: T[];
  error: Error | null;
}

// Filter and sort types
export interface SortParams {
  field: string;
  direction: "asc" | "desc";
}

export interface FilterParams {
  field: string;
  operator: "eq" | "neq" | "gt" | "gte" | "lt" | "lte" | "like" | "in";
  value: unknown;
}

// Status types (can be extended per module)
export type LoadingState = "idle" | "loading" | "success" | "error";

// User role types
export type AppRole = "admin" | "contributor";

// Common form types
export interface SelectOption {
  label: string;
  value: string;
}
