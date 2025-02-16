/*
  # Fix keystroke verification array handling

  1. Changes
    - Fix array dimensionality issues
    - Improve pattern extraction
    - Add null checks and error handling
    - Ensure consistent array lengths
    - Add array validation

  2. Security
    - Maintain existing security context
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
  match_score float := 0;
  match_details keystroke_match_details;
  adaptive_threshold float;
  requesting_user uuid;
  current_dwell_times float[];
  current_flight_times float[];
  pattern_length int;
BEGIN
  -- Get the authenticated user's ID
  requesting_user := auth.uid();
  
  -- Verify the user is only accessing their own data
  IF requesting_user IS NULL OR requesting_user != user_id THEN
    RAISE EXCEPTION 'Unauthorized access';
  END IF;

  -- Get adaptive threshold
  adaptive_threshold := calculate_adaptive_threshold(user_id);

  -- Get current session's keystroke data with validation
  WITH current_keystrokes AS (
    SELECT 
      array_agg(CASE 
        WHEN dwell_time IS NULL OR dwell_time <= 0 THEN 0 
        ELSE dwell_time 
      END ORDER BY created_at) as dwell_times,
      array_agg(CASE 
        WHEN flight_time IS NULL OR flight_time < 0 THEN 0 
        ELSE flight_time 
      END ORDER BY created_at) as flight_times
    FROM keystroke_data
    WHERE session_id = verify_keystroke_pattern.session_id
      AND dwell_time IS NOT NULL  -- Ensure we have valid data
  )
  SELECT 
    COALESCE(dwell_times, ARRAY[]::float[]), 
    COALESCE(flight_times, ARRAY[]::float[])
  INTO current_dwell_times, current_flight_times
  FROM current_keystrokes;

  -- Validate current session data
  IF array_length(current_dwell_times, 1) IS NULL OR array_length(current_dwell_times, 1) = 0 THEN
    RETURN json_build_object(
      'match_score', 0,
      'error', 'No valid keystroke data found for current session'
    );
  END IF;

  pattern_length := array_length(current_dwell_times, 1);

  -- Get historical patterns with consistent dimensionality
  WITH historical_sessions AS (
    SELECT DISTINCT ON (ks.id) 
      ks.id as session_id
    FROM keystroke_sessions ks
    INNER JOIN auth_attempts aa ON aa.user_id = ks.user_id
    WHERE ks.user_id = verify_keystroke_pattern.user_id
      AND ks.id != verify_keystroke_pattern.session_id
      AND aa.success = true
    ORDER BY ks.id, aa.attempted_at DESC
    LIMIT 5
  ),
  historical_keystrokes AS (
    SELECT 
      hs.session_id,
      array_agg(CASE 
        WHEN kd.dwell_time IS NULL OR kd.dwell_time <= 0 THEN 0 
        ELSE kd.dwell_time 
      END ORDER BY kd.created_at) as dwell_times,
      array_agg(CASE 
        WHEN kd.flight_time IS NULL OR kd.flight_time < 0 THEN 0 
        ELSE kd.flight_time 
      END ORDER BY kd.created_at) as flight_times
    FROM historical_sessions hs
    INNER JOIN keystroke_data kd ON kd.session_id = hs.session_id
    GROUP BY hs.session_id
    HAVING array_length(array_agg(kd.dwell_time), 1) = pattern_length  -- Ensure matching length
  )
  SELECT array_agg(
    normalize_keystroke_pattern(dwell_times, flight_times)
  )
  INTO historical_patterns
  FROM historical_keystrokes;

  -- Normalize current pattern
  current_pattern := normalize_keystroke_pattern(
    current_dwell_times,
    current_flight_times
  );

  -- Handle case with no historical patterns
  IF historical_patterns IS NULL OR array_length(historical_patterns, 1) = 0 THEN
    RETURN json_build_object(
      'match_score', 0.5,
      'threshold', adaptive_threshold,
      'details', json_build_object(
        'reason', 'No historical patterns available for comparison'
      )
    );
  END IF;

  -- Calculate match details with error handling
  BEGIN
    SELECT 
      COALESCE(avg(dwell_match), 0)::float as dwell_time_match,
      COALESCE(avg(flight_match), 0)::float as flight_time_match,
      COALESCE(stddev(total_match), 0)::float as pattern_consistency,
      COALESCE((avg(total_match) * (1 - COALESCE(stddev(total_match), 0))), 0)::float as overall_confidence
    INTO match_details
    FROM (
      SELECT
        1.0 / (1.0 + sqrt(sum(power(c[1] - h[1], 2)) / pattern_length)) as dwell_match,
        1.0 / (1.0 + sqrt(sum(power(c[2] - h[2], 2)) / pattern_length)) as flight_match,
        1.0 / (1.0 + sqrt(sum(power(c[1] - h[1], 2) + power(c[2] - h[2], 2)) / (2 * pattern_length))) as total_match
      FROM unnest(current_pattern) WITH ORDINALITY AS c(value, idx)
      CROSS JOIN unnest(historical_patterns) AS historical_pattern
      JOIN unnest(historical_pattern) WITH ORDINALITY AS h(value, idx) ON c.idx = h.idx
      GROUP BY historical_pattern
    ) pattern_matches;

    -- Calculate final match score with weighted features
    match_score := (
      COALESCE(match_details.dwell_time_match, 0) * 0.4 +
      COALESCE(match_details.flight_time_match, 0) * 0.4 +
      COALESCE(match_details.pattern_consistency, 0) * 0.2
    ) * COALESCE(match_details.overall_confidence, 1);

  EXCEPTION WHEN OTHERS THEN
    -- Handle any calculation errors gracefully
    RETURN json_build_object(
      'match_score', 0,
      'error', 'Error calculating pattern match: ' || SQLERRM
    );
  END;

  -- Return comprehensive match results
  RETURN json_build_object(
    'match_score', match_score,
    'threshold', adaptive_threshold,
    'details', json_build_object(
      'dwell_time_match', match_details.dwell_time_match,
      'flight_time_match', match_details.flight_time_match,
      'pattern_consistency', match_details.pattern_consistency,
      'overall_confidence', match_details.overall_confidence,
      'patterns_compared', array_length(historical_patterns, 1),
      'pattern_length', pattern_length
    ),
    'recommendation', CASE 
      WHEN match_score >= adaptive_threshold THEN 'accept'
      WHEN match_score >= adaptive_threshold * 0.8 THEN 'challenge'
      ELSE 'reject'
    END
  );
END;
$$;

-- Update comments
COMMENT ON FUNCTION verify_keystroke_pattern IS 'Verifies keystroke patterns with improved error handling and array validation';