# GaussianSystem.gd
# Autoload singleton — shared Gaussian / normal-distribution utilities.
#
# Per Project.md §6 ("The Gaussian Design Philosophy"), every major system in
# this game samples from a normal distribution rather than using deterministic
# thresholds. Centralising sampling here ensures we use the same RNG state and
# the same Box-Muller transform everywhere, so seeded saves remain deterministic
# once we wire RNG seeding into the save file.

extends Node


# Sample one value from a normal distribution.
# Uses the Box-Muller transform: two uniform [0,1) samples → one normal sample.
#
# Args:
#   mean (float): Centre of the distribution.
#   std_dev (float): Standard deviation. <=0 returns mean unchanged.
# Returns:
#   float: One value from N(mean, std_dev). Unbounded (can be far from mean).
func sample(mean: float, std_dev: float) -> float:
	if std_dev <= 0.0:
		return mean
	# Floor u1 above zero so log() doesn't blow up at the tail.
	var u1: float = maxf(randf(), 1e-9)
	var u2: float = randf()
	var z: float = sqrt(-2.0 * log(u1)) * cos(TAU * u2)
	return mean + z * std_dev


# Sample then clamp into [min_v, max_v]. Use when the simulated quantity has
# physical bounds (a harvest can't be infinitely negative, satisfaction is 0..100).
#
# Args:
#   mean (float): Distribution centre.
#   std_dev (float): Standard deviation.
#   min_v (float): Inclusive lower bound on the returned value.
#   max_v (float): Inclusive upper bound on the returned value.
# Returns:
#   float: clampf(sample(mean, std_dev), min_v, max_v).
func sample_clamped(mean: float, std_dev: float, min_v: float, max_v: float) -> float:
	return clampf(sample(mean, std_dev), min_v, max_v)

# Harvest rolls used to live here as `harvest_roll()` with hard-coded constants.
# They were moved to GameState (and the harvest_params table) in schema v2 so
# climate events can shift them and so different seasons can roll differently.
# Call GameState.get_harvest_params(season) + GaussianSystem.sample_clamped(...)
# instead.
