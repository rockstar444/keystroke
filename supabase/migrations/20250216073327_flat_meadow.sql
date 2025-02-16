/*
  # Final fix for keystroke verification

  1. Changes
    - Add array alignment and validation
    - Improve pattern normalization
    - Add robust error handling
    - Fix array dimensionality issues
    - Add data sanitization

  2. Security
    - Maintain existing security context
    - Add input validation
*/

-- Create helper function for array validation
CREATE OR REPLACE FUNCTION validate_keystroke_array(
  arr float[]
) RETURNS float[]
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN array(
    SELECT CASE
      WHEN value IS NULL OR value < 0 OR value > 5000 THEN 0 -- Cap at 5 seconds
      ELSE value
    END
    FROM unnest(arr) value
  );
END;
$$;

-- Improve pattern normalization
CREATE OR REPLACE FUNCTION normalize_keystroke_pattern(
  dwell_times float[],
  flight_times float[]
) RETURNS float[]
LANGUAGE plpgsql
AS $$
DECLARE
  normalized float[];
  dwell_mean float;
  dwell_std float;
  flight_mean float;
  flight_std float;
  min_std constant float := 0.0001; -- Prevent division by zero
BEGIN
  -- Validate input arrays
  dwell_times := validate_keystroke_array(dwell_times);
  flight_times := validate_keystroke_array(flight_times);

  -- Ensure arrays have same length
  IF array_length(dwell_times, 1) != array_length(flight_times, 1) THEN
    RETURN NULL;
  END IF;

  -- Calculate statistics
  SELECT 
    avg(d), GREATEST(stddev(d), min_std),
    avg(f), GREATEST(stddev(f), min_std)
  INTO dwell_mean, dwell_std, flight_mean, flight_std
  FROM unnest(dwell_times) d, unnest(flight_times) f;

  -- Create normalized pattern array
  normalized := array(
    SELECT ARRAY[
      (d - dwell_mean) / dwell_std,
      (f - flight_mean) / flight_std
    ]
    FROM unnest(dwell_times, flight_times) AS t(d, f)
  );

  RETURN normalized;
END;
$$;

-- Update verify_keystroke_pattern function
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
  match_score float := 0;
  match_details keystroke_match_details;
  adaptive_threshold float;
  requesting_user uuid;
  current_dwell_times float[];
  current_flight_times float[];
  pattern_length int;
BEGIN
  -- Security check
  requesting_user := auth.uid();
  IF requesting_user IS NULL OR requesting_user != user_id THEN
    RAISE EXCEPTION 'Unauthorized access';
  END IF;

  -- Get current session's keystroke data
  WITH current_keystrokes AS (
    SELECT 
      array_agg(dwell_time ORDER BY created_at) as dwell_times,
      array_agg(flight_time ORDER BY created_at) as flight_times,
      count(*) as keystroke_count
    FROM keystroke_data
    WHERE session_id = verify_keystroke_pattern.session_id
  )
  SELECT 
    COALESCE(dwell_times, ARRAY[]::float[]),
    COALESCE(flight_times, ARRAY[]::float[]),
    keystroke_count
  INTO current_dwell_times, current_flight_times, pattern_length
  FROM current_keystrokes;

  -- Validate current session data
  IF pattern_length = 0 THEN
    RETURN json_build_object(
      'match_score', 0,
      'error', 'No keystroke data found for current session'
    );
  END IF;

  -- Get historical patterns
  WITH historical_sessions AS (
    SELECT DISTINCT ON (ks.id)
      ks.id as session_id,
      aa.attempted_at
    FROM keystroke_sessions ks
    JOIN auth_attempts aa ON aa.user_id = ks.user_id
    WHERE ks.user_id = verify_keystroke_pattern.user_id
      AND ks.id != verify_keystroke_pattern.session_id
      AND aa.success = true
    ORDER BY ks.id, aa.attempted_at DESC
    LIMIT 5
  ),
  historical_keystrokes AS (
    SELECT 
      hs.session_id,
      array_agg(kd.dwell_time ORDER BY kd.created_at) as dwell_times,
      array_agg(kd.flight_time ORDER BY kd.created_at) as flight_times
    FROM historical_sessions hs
    JOIN keystroke_data kd ON kd.session_id = hs.session_id
    GROUP BY hs.session_id, hs.attempted_at
    HAVING count(*) = pattern_length
    ORDER BY hs.attempted_at DESC
  )
  SELECT array_agg(
    normalize_keystroke_pattern(
      validate_keystroke_array(dwell_times),
      validate_keystroke_array(flight_times)
    )
  )
  INTO historical_patterns
  FROM historical_keystrokes
  WHERE dwell_times IS NOT NULL 
    AND flight_times IS NOT NULL
    AND array_length(dwell_times, 1) = pattern_length
    AND array_length(flight_times, 1) = pattern_length;

  -- Normalize current pattern
  current_pattern := normalize_keystroke_pattern(
    current_dwell_times,
    current_flight_times
  );

  -- Handle case with no valid patterns
  IF current_pattern IS NULL OR historical_patterns IS NULL OR array_length(historical_patterns, 1) = 0 THEN
    RETURN json_build_object(
      'match_score', 0.5,
      'details', json_build_object(
        'reason', 'Insufficient data for comparison',
        'current_length', array_length(current_dwell_times, 1),
        'historical_patterns', COALESCE(array_length(historical_patterns, 1), 0)
      )
    );
  END IF;

  -- Calculate match score
  BEGIN
    WITH pattern_matches AS (
      SELECT
        1.0 / (1.0 + sqrt(sum(power(c.value[1] - h.value[1], 2) + power(c.value[2] - h.value[2], 2)) / (2 * pattern_length))) as similarity
      FROM unnest(current_pattern) WITH ORDINALITY AS c(value, idx)
      CROSS JOIN unnest(historical_patterns) AS hp
      JOIN unnest(hp) WITH ORDINALITY AS h(value, idx) ON c.idx = h.idx
      GROUP BY hp
    )
    SELECT 
      avg(similarity)::float
    INTO match_score
    FROM pattern_matches;

    match_score := COALESCE(match_score, 0);

  EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
      'match_score', 0,
      'error', 'Error calculating match: ' || SQLERRM
    );
  END;

  -- Return results
  RETURN json_build_object(
    'match_score', match_score,
    'details', json_build_object(
      'patterns_compared', array_length(historical_patterns, 1),
      'pattern_length', pattern_length,
      'recommendation', CASE 
        WHEN match_score >= 0.7 THEN 'accept'
        WHEN match_score >= 0.5 THEN 'challenge'
        ELSE 'reject'
      END
    )
  );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION validate_keystroke_array(float[]) TO authenticated;
GRANT EXECUTE ON FUNCTION normalize_keystroke_pattern(float[], float[]) TO authenticated;
GRANT EXECUTE ON FUNCTION verify_keystroke_pattern(uuid, uuid) TO authenticated;

-- Add comments
COMMENT ON FUNCTION validate_keystroke_array IS 'Validates and sanitizes keystroke timing arrays';
COMMENT ON FUNCTION normalize_keystroke_pattern IS 'Normalizes keystroke patterns with improved validation';
COMMENT ON FUNCTION verify_keystroke_pattern IS 'Verifies keystroke patterns with robust error handling';