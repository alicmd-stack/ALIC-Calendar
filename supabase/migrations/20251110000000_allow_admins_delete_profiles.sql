-- Add policy to allow admins to delete profiles
-- This enables admins to remove users from the system via the Users management page

CREATE POLICY "Admins can delete all profiles"
  ON public.profiles FOR DELETE
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));
