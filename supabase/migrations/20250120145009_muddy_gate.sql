/*
  # Fix ambiguous column references and query issues

  1. Updates
    - Fix ambiguous session_id references in verify_keystroke_pattern function
    - Add proper table aliases to avoid column ambiguity
    - Improve query performance with proper joins

  2. Changes
    - Modify verify_keystroke_pattern function to use explicit table references
    - Update historical pattern retrieval logic
*/

CREATE OR REPLACE FUNCTION verify_keystroke_pattern(
  user_id uuid,
  session_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_pattern float[];
  historical_patterns float[][];
  match_score float;
  total_score float := 0;
  pattern_count int := 0;
  requesting_user uuid;
BEGIN
  -- Get the authenticated user's ID
  requesting_user := auth.uid();
  
  -- Verify the user is only accessing their own data
  IF requesting_user IS NULL OR requesting_user != user_id THEN
    RAISE EXCEPTION 'Unauthorized access';
  END IF;

  -- Get current session's keystroke pattern (dwell times and flight times)
  WITH current_keystrokes AS (
    SELECT 
      kd.dwell_time,
      kd.flight_time
    FROM keystroke_data kd
    WHERE kd.session_id = verify_keystroke_pattern.session_id
    ORDER BY kd.created_at
  )
  SELECT array_agg(ARRAY[dwell_time, COALESCE(flight_time, 0)]::float[])
  INTO current_pattern
  FROM current_keystrokes;

  -- Get historical patterns from previous successful sessions
  WITH historical_sessions AS (
    SELECT DISTINCT ks.id
    FROM keystroke_sessions ks
    INNER JOIN auth_attempts aa ON aa.user_id = ks.user_id
    WHERE ks.user_id = verify_keystroke_pattern.user_id
      AND ks.id != verify_keystroke_pattern.session_id
      AND aa.success = true
    LIMIT 5
  ),
  historical_keystrokes AS (
    SELECT 
      kd.session_id,
      array_agg(ARRAY[kd.dwell_time, COALESCE(kd.flight_time, 0)]::float[] ORDER BY kd.created_at) as pattern
    FROM keystroke_data kd
    INNER JOIN historical_sessions hs ON hs.id = kd.session_id
    GROUP BY kd.session_id
  )
  SELECT array_agg(pattern)
  INTO historical_patterns
  FROM historical_keystrokes;

  -- If no historical patterns exist, return a neutral score
  IF historical_patterns IS NULL THEN
    RETURN json_build_object('match_score', 0.5);
  END IF;

  -- Compare current pattern with historical patterns
  FOR i IN 1..array_length(historical_patterns, 1) LOOP
    IF array_length(current_pattern, 1) = array_length(historical_patterns[i], 1) THEN
      -- Calculate similarity score using normalized Euclidean distance
      SELECT 1.0 / (1.0 + sqrt(sum((p1.value - p2.value)^2) / array_length(current_pattern, 1)))
      INTO match_score
      FROM unnest(current_pattern) WITH ORDINALITY AS p1(value, idx)
      JOIN unnest(historical_patterns[i]) WITH ORDINALITY AS p2(value, idx) ON p1.idx = p2.idx;
      
      total_score := total_score + match_score;
      pattern_count := pattern_count + 1;
    END IF;
  END LOOP;

  -- Return average similarity score
  RETURN json_build_object(
    'match_score',
    CASE 
      WHEN pattern_count > 0 THEN total_score / pattern_count
      ELSE 0.5
    END
  );
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION verify_keystroke_pattern(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION verify_keystroke_pattern IS 'Verifies a user''s keystroke pattern against their historical data';