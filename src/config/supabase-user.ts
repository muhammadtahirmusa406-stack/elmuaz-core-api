import { createClient } from "@supabase/supabase-js";
import { env } from "./env.js";

export function createUserSupabaseClient(accessToken: string) {
  return createClient(
    env.supabaseUrl,
    env.supabaseAnonKey,
    {
      global: {
        headers: {
          Authorization: `Bearer ${accessToken}`,
        },
      },
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    },
  );
}