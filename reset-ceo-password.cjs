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
  const { data, error } = await supabase.auth.admin.updateUserById(
    "32e84163-6704-4d87-b96e-6a6121a580ae",
    { password: "Mahrab000" }
  );

  if (error) {
    console.error("RESET FAILED:", error.message);
    process.exit(1);
  }

  console.log("RESET SUCCESS");
  console.log("User:", data.user.email);
})();
