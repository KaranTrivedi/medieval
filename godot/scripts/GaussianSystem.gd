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


# Per-county harvest multiplier per Project.md §10:
#   Mean    = 3× seed planted        → normalised to 1.0
#   StdDev  = 1.2× seed              → normalised to 0.4
#   Min     = 0.5× seed (famine)     → normalised to 0.167
#   Max     = 6× seed (bumper crop)  → normalised to 2.0
# Multiply this against a county's base income to get the year's actual income.
#
# Returns:
#   float: Harvest multiplier in [0.167, 2.0]. Mean ~1.0, σ ~0.4.
func harvest_roll() -> float:
	return sample_clamped(1.0, 0.4, 0.167, 2.0)
