// ============================================================
// Supabase client configuration
// ============================================================
// These are PUBLIC values — safe to commit and serve to the browser.
// RLS policies in the database are what protect data, not these keys.
//
// To rotate the publishable key: Supabase Dashboard → Settings → API → Rotate.
// (Don't put service_role / secret keys here — they bypass RLS.)
// ============================================================

export const SUPABASE_URL = 'https://njydqslqldphvrcnrrsq.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_S5XbkycQhDrZZmOVKx9h3g_QDlzTEqw';

// Initialize the global client — assumes `supabase` UMD is loaded from CDN.
// (See <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script> in index.html)
export function createSupabaseClient() {
  if (typeof supabase === 'undefined') {
    throw new Error('Supabase SDK not loaded — make sure the CDN <script> tag is included before this module.');
  }
  return supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: {
      // Persist session across reloads (in localStorage)
      persistSession: true,
      // Auto-refresh tokens before expiry
      autoRefreshToken: true,
      // Detect signin in URL fragments (for email confirm / password reset)
      detectSessionInUrl: true,
    },
  });
}
