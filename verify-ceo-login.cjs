const { createClient } = require("@supabase/supabase-js");

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false
    }
  }
);

(async () => {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: "eims16-ceo@example.invalid",
    password: "Mahrab000"
  });

  if (error) {
    console.error("LOGIN FAILED:", error.message);
    process.exit(1);
  }

  console.log("LOGIN VERIFIED SUCCESSFULLY");
  console.log("User:", data.user.email);
})();
