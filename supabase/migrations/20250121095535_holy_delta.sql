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
      array_agg(ARRAY[
        dwell_time::float,
        COALESCE(flight_time, 0)::float
      ] ORDER BY created_at) as pattern
    FROM keystroke_data
    WHERE session_id = verify_keystroke_pattern.session_id
    GROUP BY session_id
  )
  SELECT pattern INTO current_pattern
  FROM current_keystrokes;

  -- Get historical patterns from previous successful sessions
  WITH historical_sessions AS (
    SELECT DISTINCT ks.id
    FROM keystroke_sessions ks
    INNER JOIN auth_attempts aa ON aa.user_id = ks.user_id
    WHERE ks.user_id = verify_keystroke_pattern.user_id
      AND ks.id != verify_keystroke_pattern.session_id
      AND aa.success = true
    ORDER BY aa.attempted_at DESC
    LIMIT 5
  ),
  historical_keystrokes AS (
    SELECT 
      kd.session_id,
      array_agg(ARRAY[
        dwell_time::float,
        COALESCE(flight_time, 0)::float
      ] ORDER BY created_at) as pattern
    FROM keystroke_data kd
    INNER JOIN historical_sessions hs ON hs.id = kd.session_id
    GROUP BY kd.session_id
  )
  SELECT array_agg(pattern ORDER BY session_id)
  INTO historical_patterns
  FROM historical_keystrokes;

  -- If no historical patterns exist, return a neutral score
  IF historical_patterns IS NULL OR current_pattern IS NULL THEN
    RETURN json_build_object('match_score', 0.5);
  END IF;

  -- Compare current pattern with historical patterns
  FOR i IN 1..array_length(historical_patterns, 1) LOOP
    -- Skip if patterns have different lengths
    IF array_length(current_pattern, 1) = array_length(historical_patterns[i], 1) THEN
      -- Calculate similarity score using normalized Euclidean distance
      WITH pattern_comparison AS (
        SELECT 
          1.0 / (1.0 + sqrt(
            sum(
              power(c[1] - h[1], 2) + -- Compare dwell times
              power(c[2] - h[2], 2)    -- Compare flight times
            ) / (2 * array_length(current_pattern, 1))
          )) as similarity
        FROM unnest(current_pattern) WITH ORDINALITY AS c_data(c, idx)
        JOIN unnest(historical_patterns[i]) WITH ORDINALITY AS h_data(h, idx) 
          ON c_data.idx = h_data.idx
      )
      SELECT similarity INTO match_score FROM pattern_comparison;
      
      total_score := total_score + COALESCE(match_score, 0);
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