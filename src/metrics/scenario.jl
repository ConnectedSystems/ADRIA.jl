"""Scenario-level summaries.

Note: Aggregates across the `site` dimension so trajectories over time for each scenario are returned.
      The difference between these and `temporal` metrics is that these methods keep the scenario dimension.

TODO: Produce summary stats. Currently returns just the mean.
"""


"""
    scenario_total_cover(rs::ResultSet; kwargs...)

Calculate the cluster-wide total absolute coral cover for each scenario.
"""
function _scenario_total_cover(rs::ResultSet; kwargs...)
    return dropdims(sum(slice_results(total_absolute_cover(rs); kwargs...), dims=:sites), dims=:sites)
end
scenario_total_cover = Metric(_scenario_total_cover, (:timesteps, :scenarios), "m²")


"""
    scenario_relative_cover(rs::ResultSet; kwargs...)

Calculate the cluster-wide relative coral cover for each scenario.
"""
function _scenario_relative_cover(rs::ResultSet; kwargs...)
    target_sites = haskey(kwargs, :sites) ? kwargs[:sites] : (:)
    target_area = sum(((rs.site_max_coral_cover./100.0).*rs.site_area)[target_sites])

    return _scenario_total_cover(rs; kwargs...) ./ target_area
end
scenario_relative_cover = Metric(_scenario_relative_cover, (:timesteps, :scenarios))


"""
    scenario_juveniles(data::NamedDimsArray; kwargs...)

Calculate the cluster-wide juvenile population for individual scenarios.
"""
function _scenario_juveniles(data::NamedDimsArray; kwargs...)
    juv = call_metric(relative_juveniles, data; kwargs...)
    return dropdims(sum(juv, dims=:sites), dims=:sites)
end
function _scenario_juveniles(rs::ResultSet; kwargs...)
    return dropdims(sum(slice_results(rs.outcomes[:relative_juveniles]; kwargs...), dims=:sites), dims=:sites)
end
scenario_juveniles = Metric(_scenario_juveniles, (:scenario, :timesteps))


"""
    scenario_asv(sv::NamedDimsArray; kwargs...)
    scenario_asv(rs::ResultSet; kwargs...)

Calculate the cluster-wide absolute shelter volume for each scenario.
"""
function _scenario_asv(sv::NamedDimsArray{<:Real}; kwargs...)
    sv_sliced = slice_results(sv; kwargs...)
    return dropdims(sum(sv_sliced, dims=:sites), dims=:sites)
end
function _scenario_asv(rs::ResultSet; kwargs...)
    return _scenario_asv(rs.outcomes[:absolute_shelter_volume]; kwargs...)
end
scenario_asv = Metric(_scenario_asv, (:scenario, :timesteps), "m³/m²")


"""
    scenario_rsv(sv::NamedDimsArray; kwargs...)
    scenario_rsv(rs::ResultSet; kwargs...)

Calculate the cluster-wide mean relative shelter volumes for each scenario.
"""
function _scenario_rsv(sv::NamedDimsArray; kwargs...)
    sv_sliced = slice_results(sv; kwargs...)
    return dropdims(mean(sv_sliced, dims=:sites), dims=:sites)
end
function _scenario_rsv(rs::ResultSet; kwargs...)
    return _scenario_rsv(rs.outcomes[:relative_shelter_volume]; kwargs...)
end
scenario_rsv = Metric(_scenario_rsv, (:scenario, :timesteps))
