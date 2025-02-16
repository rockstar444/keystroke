/*
  # Add Keystroke Dynamics Policies

  1. Changes
    - Add insert policy for profiles table
    - Add delete policies for all tables
    - Add trigger for updating dwell and flight times

  2. Security
    - Add additional RLS policies for data management
*/

-- Add insert policy for profiles
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'profiles' AND policyname = 'Users can insert own profile'
  ) THEN
    CREATE POLICY "Users can insert own profile"
      ON profiles FOR INSERT
      TO authenticated
      WITH CHECK (auth.uid() = id);
  END IF;
END $$;

-- Add delete policies
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'profiles' AND policyname = 'Users can delete own profile'
  ) THEN
    CREATE POLICY "Users can delete own profile"
      ON profiles FOR DELETE
      TO authenticated
      USING (auth.uid() = id);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'keystroke_sessions' AND policyname = 'Users can delete own sessions'
  ) THEN
    CREATE POLICY "Users can delete own sessions"
      ON keystroke_sessions FOR DELETE
      TO authenticated
      USING (user_id = auth.uid());
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'keystroke_data' AND policyname = 'Users can delete own keystroke data'
  ) THEN
    CREATE POLICY "Users can delete own keystroke data"
      ON keystroke_data FOR DELETE
      TO authenticated
      USING (session_id IN (
        SELECT id FROM keystroke_sessions WHERE user_id = auth.uid()
      ));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'auth_attempts' AND policyname = 'Users can delete own auth attempts'
  ) THEN
    CREATE POLICY "Users can delete own auth attempts"
      ON auth_attempts FOR DELETE
      TO authenticated
      USING (user_id = auth.uid());
  END IF;
END $$;

-- Create function to calculate dwell and flight times
CREATE OR REPLACE FUNCTION calculate_keystroke_times()
RETURNS TRIGGER AS $$
BEGIN
  NEW.dwell_time := NEW.release_time - NEW.press_time;
  
  -- Calculate flight time if there's a previous keystroke
  IF EXISTS (
    SELECT 1 FROM keystroke_data 
    WHERE session_id = NEW.session_id 
    AND created_at < NEW.created_at
    ORDER BY created_at DESC 
    LIMIT 1
  ) THEN
    NEW.flight_time := NEW.press_time - (
      SELECT release_time 
      FROM keystroke_data 
      WHERE session_id = NEW.session_id 
      AND created_at < NEW.created_at
      ORDER BY created_at DESC 
      LIMIT 1
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for keystroke timing calculations
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger 
    WHERE tgname = 'calculate_keystroke_times_trigger'
  ) THEN
    CREATE TRIGGER calculate_keystroke_times_trigger
      BEFORE INSERT ON keystroke_data
      FOR EACH ROW
      EXECUTE FUNCTION calculate_keystroke_times();
  END IF;
END $$;