"""Scenario running functions"""


import ADRIA.metrics: relative_cover, total_absolute_cover, absolute_shelter_volume, relative_shelter_volume


"""
    setup_cache(domain::Domain)::NamedTuple

Establish tuple of matrices/vectors for use as reusable data stores to avoid repeated memory allocations.
"""
function setup_cache(domain::Domain)::NamedTuple

    # sim constants
    n_sites::Int64 = domain.coral_growth.n_sites
    n_species::Int64 = domain.coral_growth.n_species
    n_groups::Int64 = domain.coral_growth.n_groups

    # Strip names from NamedArrays
    init_cov = Matrix{Float64}(domain.init_coral_cover)

    cache = (
        sf = zeros(n_groups, n_sites),
        fec_all = zeros(size(init_cov)...),
        fec_scope = zeros(n_groups, n_sites),
        prop_loss = zeros(n_species, n_sites),
        Sbl = zeros(n_species, n_sites),
        dhw_step = zeros(n_sites),
        init_cov = init_cov,
        cov_tmp = zeros(size(init_cov)...),
        site_area = Array{Float64}(domain.site_data.area'),
        TP_data = Array{Float64, 2}(domain.TP_data)
    )

    return cache
end


"""
    run_scenarios(param_df::DataFrame, domain::Domain; metrics::Array=[])

Run scenarios defined by the parameter table storing results to disk.
Scenarios are run in parallel where the number of scenarios > 16.

# Notes
Returned `domain` holds scenario invoke time used as unique result set identifier.

# Arguments
- param_df : DataFrame of scenarios to run
- domain : Domain, to run scenarios with
- metrics : Outcomes to store. Defaults to raw data only.

# Returns
domain
"""
function run_scenarios(param_df::DataFrame, domain::Domain)::Domain
    has_setup()

    domain, data_store = ADRIA.setup_result_store!(domain, param_df)
    cache = setup_cache(domain)

    # Spin up workers if needed
    if nprocs() == 1 && (parse(Bool, ENV["ADRIA_DEBUG"]) == false)
        active_cores = parse(Int, ENV["ADRIA_NUM_CORES"])
        if active_cores <= 0
            active_cores = cpucores()
        end

        if active_cores > 1
            addprocs(active_cores, exeflags="--project")
        end
    end

    # Batch run scenarios
    if (nrow(param_df) > 256) && (parse(Bool, ENV["ADRIA_DEBUG"]) == false)
        @eval @everywhere using ADRIA

        func = (dfx) -> run_scenario(dfx, domain, data_store, cache)
        @showprogress "Running..." 4 pmap(func, enumerate(eachrow(param_df)))
    else
        func = (dfx) -> run_scenario(dfx, domain, data_store, cache)
        @showprogress "Running..." 1 map(func, enumerate(eachrow(param_df)))
    end

    return domain
end


"""
    run_scenarios(scen::Tuple{Int, DataFrameRow}, domain::Domain, data_store::NamedTuple, cache::NamedTuple, metrics=[])

Run individual scenarios for a given domain.

Stores results on disk in Zarr format at pre-configured location.

# Notes
Logs of site ranks only store the mean site rankings over all environmental scenarios.
This is to reduce the volume of data stored.
"""
function run_scenario(scen::Tuple{Int, DataFrameRow}, domain::Domain, data_store::NamedTuple, cache::NamedTuple)
    # Update model with values in given DF row
    update_params!(domain, scen[2])

    dhw_scen = scen[2].dhw_scenario
    wave_scen = scen[2].wave_scenario

    # TODO: Modify all scenario constants here to avoid repeated allocations
    @set! domain.coral_growth.ode_p.k = (domain.site_data.k::Vector{Float64} / 100.0)  # Max possible cover at site
    @set! domain.coral_growth.ode_p.comp = domain.sim_constants.comp::Float64  # competition rate between two mature coral groups

    run_scenario(domain; idx=scen[1], dhw=dhw_scen, wave=wave_scen, data_store=data_store, cache=cache)
end
function run_scenario(scen::Tuple{Int, DataFrameRow}, domain::Domain, data_store::NamedTuple)
    run_scenario(scen, domain, data_store, setup_cache(domain))
end


"""
    run_scenario(domain::Domain; idx=1, dhw=1, wave=1, data_store::NamedTuple, cache::NamedTuple)::NamedTuple

Convenience function to directly run a scenario for a Domain with pre-set values.

Stores results on disk in Zarr format at pre-configured location.

# Notes
Logs of site ranks only store the mean site rankings over all environmental scenarios.
This is to reduce the volume of data stored.
"""
function run_scenario(domain::Domain; idx::Int=1, dhw::Int=1, wave::Int=1, data_store::NamedTuple, cache::NamedTuple)
    tf::Int64 = domain.sim_constants.tf

    # Extract non-coral parameters
    df = DataFrame(domain.model)
    not_coral_params = df[!, :component] .!== Coral
    param_set = NamedTuple{tuple(df[not_coral_params, :fieldname]...)}(df[not_coral_params, :val])

    # Expand coral model to include its specifications across all taxa/species/groups
    coral_params = to_spec(component_params(domain.model, Coral))

    # Pass in environmental layer data stripped of named dimensions.
    all_dhws = Array{Float64}(domain.dhw_scens[1:tf, :, :])
    all_waves = Array{Float64}(domain.wave_scens[1:tf, :, :])

    result_set = run_scenario(domain, param_set, coral_params, domain.sim_constants, domain.site_data,
                                     domain.coral_growth.ode_p,
                                     all_dhws[:, :, dhw], all_waves[:, :, wave], cache)

    # Capture results to disk
    # Set values below threshold to 0 to save space
    threshold = parse(Float32, ENV["ADRIA_THRESHOLD"])
    tmp_site_ranks = zeros(Float32, tf, nrow(domain.site_data), 2)

    r_raw = result_set.raw
    vals = relative_cover(r_raw)
    vals[vals .< threshold] .= 0.0
    data_store.relative_cover[:, :, idx] .= vals

    vals .= absolute_shelter_volume(r_raw, site_area(domain), param_table(domain))
    vals[vals .< threshold] .= 0.0
    data_store.absolute_shelter_volume[:, :, idx] .= vals

    vals .= relative_shelter_volume(r_raw, site_area(domain), param_table(domain))
    vals[vals .< threshold] .= 0.0
    data_store.relative_shelter_volume[:, :, idx] .= vals

    # Store raw results if no metrics specified
    # if length(metrics) == 0
    #     data_store.raw[:, :, :, idx] .= r.raw
    # end

    # Store logs
    c_dim = Base.ndims(result_set.raw) + 1
    log_stores = (:site_ranks, :seed_log, :fog_log, :shade_log)
    for k in log_stores
        if k == :seed_log || k == :site_ranks
            concat_dim = c_dim
        else
            concat_dim = c_dim - 1
        end

        vals = getfield(result_set, k)
        vals[vals .< threshold] .= 0.0

        if k == :seed_log
            getfield(data_store, k)[:, :, :, idx] .= vals
        elseif k == :site_ranks
            tmp_site_ranks[:, :, :] .= vals
        else
            getfield(data_store, k)[:, :, idx] .= vals
        end
    end

    if !isnothing(data_store.site_ranks)
        # Squash site ranks down to average rankings over environmental repeats
        data_store.site_ranks[:, :, :, idx] .= tmp_site_ranks
    end
end


"""
    run_scenario(param_df, domain)

Run a single scenario and return results.
"""
function run_scenario(param_df::DataFrameRow, domain::Domain)::NamedTuple
    has_setup()

    # Update model with values in given DF row
    update_params!(domain, param_df)

    param_set = NamedTuple{domain.model[:fieldname]}(domain.model[:val])

    # Expand coral model to include its specifications across all taxa/species/groups
    coral_params = to_spec(component_params(domain.model, Coral))

    dhw_rep_id = param_df.dhw_scenario
    wave_rep_id = param_df.wave_scenario

    cache = setup_cache(domain)
    return run_scenario(domain, param_set, coral_params, domain.sim_constants, domain.site_data,
                        domain.coral_growth.ode_p,
                        Matrix{Float64}(domain.dhw_scens[1:tf, :, dhw_rep_id]),
                        Matrix{Float64}(domain.wave_scens[1:tf, :, wave_rep_id]), cache)
end


"""
    run_scenario(domain, param_set, corals, sim_params, site_data, p::NamedTuple,
                 dhw_scen::Array, wave_scen::Array, cache::NamedTuple)::NamedTuple

Core scenario running function.

# Notes
Only the mean site rankings are kept
"""
function run_scenario(domain::Domain, param_set::NamedTuple, corals::DataFrame, sim_params::SimConstants, site_data::DataFrame,
    p::NamedTuple, dhw_scen::Matrix{Float64},
    wave_scen::Matrix{Float64}, cache::NamedTuple)::NamedTuple

    # Set random seed using intervention values
    # TODO: More robust way of getting intervention/criteria values
    rnd_seed_val = floor(Int, sum([copy(getindex(param_set, i)) for i in 1:26]))
    Random.seed!(rnd_seed_val)

    ### TODO: All cached arrays/values to be moved to outer function and passed in
    # to reduce overall allocations (e.g., sim constants don't change across all scenarios)

    tspan::Tuple = (0.0, 1.0)
    solver::RK4 = RK4()

    MCDA_approach::Int64 = param_set.guided

    # sim constants
    n_sites::Int64 = domain.coral_growth.n_sites
    nsiteint::Int64 = sim_params.nsiteint
    tf::Int64 = sim_params.tf
    n_species::Int64 = domain.coral_growth.n_species
    n_groups::Int64 = domain.coral_growth.n_groups

    # years to start seeding/shading
    seed_start_year::Int64 = param_set.seed_year_start
    shade_start_year::Int64 = param_set.shade_year_start

    n_TA_to_seed::Int64 = param_set.seed_TA  # tabular Acropora size class 2, per year per species per cluster
    n_CA_to_seed::Int64 = param_set.seed_CA  # corymbose Acropora size class 2, per year per species per cluster
    fogging::Real = param_set.fogging  # percent reduction in bleaching mortality through fogging
    srm::Real = param_set.SRM  # DHW equivalents reduced by some shading mechanism
    seed_years::Int64 = param_set.seed_years  # number of years to seed
    shade_years::Int64 = param_set.shade_years  # number of years to shade

    # Gompertz shape parameters for bleaching
    neg_e_p1::Real = -sim_params.gompertz_p1
    neg_e_p2::Real = -sim_params.gompertz_p2

    ### END TODO

    total_site_area::Array{Float64, 2} = cache.site_area

    fec_params::Vector{Float64} = corals.fecundity
    potential_settler_cover::Float64 = (sim_params.max_settler_density *
                                        sim_params.basal_area_per_settler *
                                        sim_params.density_ratio_of_settlers_to_larvae)

    # Caches
    TP_data = cache.TP_data
    # fec_all::Array{Float64,2} = zeros(size(init_cov)...)
    # fec_scope::Array{Float64,2} = zeros(n_groups, n_sites)
    # prop_loss::Array{Float64,2} = zeros(n_species, n_sites)
    # Sbl::Array{Float64,2} = zeros(n_species, n_sites)
    # dhw_step::Vector{Float64} = zeros(n_sites)
    sf = cache.sf[:, :]
    fec_all = cache.fec_all[:, :]
    fec_scope = cache.fec_scope[:, :]
    prop_loss = cache.prop_loss[:, :]
    Sbl = cache.Sbl[:, :]
    dhw_step = cache.dhw_step[:]
    Y_tmp_cover = cache.cov_tmp[:, :]

    Y_cover::Array{Float64, 3} = zeros(tf, n_species, n_sites)  # Coral cover relative to total site area
    Y_cover[1, :, :] .= cache.init_cov[:, :]
    cover_tmp = p.cover  # pre-allocated matrix used to avoid memory allocations

    site_ranks = SparseArray(zeros(tf, n_sites, 2)) # log seeding/fogging/shading ranks
    Yshade = SparseArray(spzeros(tf, n_sites))
    Yfog = SparseArray(spzeros(tf, n_sites))
    Yseed = SparseArray(zeros(tf, 2, n_sites))  # 2 = the two enhanced coral types

    # Intervention strategy: 0 is random, > 0 is guided
    is_guided = param_set.guided > 0

    # Years at which to reassess seeding site selection
    seed_decision_years = repeat([false], tf)
    shade_decision_years = repeat([false], tf)

    if param_set.seed_freq > 0
        max_consider = min(seed_start_year+seed_years-1, tf)
        seed_decision_years[seed_start_year:param_set.seed_freq:max_consider] .= true
    else
        # Start at year 2 or the given specified seed start year
        seed_decision_years[max(seed_start_year, 2)] = true
    end

    if param_set.shade_freq > 0
        max_consider = min(shade_start_year+shade_years-1, tf)
        shade_decision_years[shade_start_year:param_set.shade_freq:max_consider] .= true
    else
        # Start at year 2 or the given specified shade start year
        shade_decision_years[max(shade_start_year, 2)] = true
    end

    prefseedsites::Vector{Int64} = zeros(Int, nsiteint)
    prefshadesites::Vector{Int64} = zeros(Int, nsiteint)

    # Max coral cover at each site. Divided by 100 to convert to proportion
    max_cover = site_data.k / 100.0

    # Set other params for ODE
    p.r .= corals.growth_rate  # Assumed growth_rate

    # Proportionally adjust initial cover (handles inappropriate initial conditions)
    Y_cover[1, :, :] .= proportional_adjustment!(Y_cover[1, :, :], cover_tmp, max_cover)

    if is_guided
        ## Weights for connectivity , waves (ww), high cover (whc) and low
        wtwaves = param_set.wave_stress # weight of wave damage in MCDA
        wtheat = param_set.heat_stress # weight of heat damage in MCDA
        wtconshade = param_set.shade_connectivity # weight of connectivity for shading in MCDA
        wtconseed = param_set.seed_connectivity # weight of connectivity for seeding in MCDA
        wthicover = param_set.coral_cover_high # weight of high coral cover in MCDA (high cover gives preference for seeding corals but high for SRM)
        wtlocover = param_set.coral_cover_low # weight of low coral cover in MCDA (low cover gives preference for seeding corals but high for SRM)
        wtpredecseed = param_set.seed_priority # weight for the importance of seeding sites that are predecessors of priority reefs
        wtpredecshade = param_set.shade_priority # weight for the importance of shading sites that are predecessors of priority reefs
        risktol = param_set.deployed_coral_risk_tol # risk tolerance

        # Defaults to considering all sites if depth cannot be considered.
        depth_priority = collect(1:nrow(site_data))

        # Filter out sites outside of desired depth range
        if .!all(site_data.depth_med .== 0)
            max_depth::Float64 = param_set.depth_min + param_set.depth_offset
            depth_criteria::BitArray{1} = (site_data.depth_med .>= param_set.depth_min) .& (site_data.depth_med .<= max_depth)

            # TODO: Include this change in MATLAB version as well
            if any(depth_criteria .> 0)
                # If sites can be filtered based on depth, do so. Otherwise if no sites can be filtered, remove depth as a criterion.
                depth_priority = depth_priority[depth_criteria]
            else
                @warn "No sites within provided depth range of $(param_set.depth_min) - $(max_depth) meters. Considering all sites."
            end
        end

        # pre-allocate rankings
        rankings = [depth_priority zeros(Int, length(depth_priority)) zeros(Int, length(depth_priority))]

        # Prep site selection
        mcda_vars = DMCDA_vars(
            depth_priority,
            nsiteint,
            sim_params.prioritysites,
            domain.strongpred,
            domain.conn_ranks,
            zeros(n_species, n_sites),  # dam prob
            dhw_scen[1, :],  # heatstressprob
            Y_cover[1, :, :],  # sumcover
            max_cover,
            total_site_area,
            risktol,
            wtconseed,
            wtconshade,
            wtwaves,
            wtheat,
            wthicover,
            wtlocover,
            wtpredecseed,
            wtpredecshade
        )
    end

    # Define constant table location for seed values
    tabular_enhanced::BitArray = corals.taxa_id .== 1
    corymbose_enhanced::BitArray = corals.taxa_id .== 3
    target_class_id::BitArray = corals.class_id .== 2
    seed_sc_TA::Int64 = first(findall(tabular_enhanced .& target_class_id))  # size class indices for TA and CA
    seed_sc_CA::Int64 = first(findall(corymbose_enhanced .& target_class_id))

    #### End coral constants

    ## Update ecological parameters based on intervention option
    # Set up assisted adaptation values
    a_adapt = zeros(n_species)
    a_adapt[tabular_enhanced] .= param_set.a_adapt
    a_adapt[corymbose_enhanced] .= param_set.a_adapt

    # Level of natural coral adaptation
    n_adapt = param_set.n_adapt  # natad = coral_params.natad + interv.Natad;
    bleach_resist = corals.bleach_resist

    ## Extract other parameters
    LPdhwcoeff = sim_params.LPdhwcoeff # shape parameters relating dhw affecting cover to larval production
    DHWmaxtot = sim_params.DHWmaxtot # max assumed DHW for all scenarios.  Will be obsolete when we move to new, shared inputs for DHW projections
    LPDprm2 = sim_params.LPDprm2 # parameter offsetting LPD curve

    # Wave stress
    mwaves::Array{Float64,3} = zeros(tf, n_species, n_sites)
    wavemort90::Vector{Float64} = corals.wavemort90::Vector{Float64}  # 90th percentile wave mortality

    @inbounds for sp::Int64 in 1:n_species
        @views mwaves[:, sp, :] .= wavemort90[sp] .* wave_scen[:, :, :]
    end

    mwaves[mwaves .< 0.0] .= 0.0
    mwaves[mwaves .> 1.0] .= 1.0

    Sw_t = 1.0 .- mwaves

    # Flag indicating whether to seed or not to seed
    seed_corals = (n_TA_to_seed > 0) || (n_CA_to_seed > 0)

    # extract colony areas for sites selected and convert to m^2
    col_area_seed_TA = corals.colony_area_cm2[seed_sc_TA] / 10^4
    col_area_seed_CA = corals.colony_area_cm2[seed_sc_CA] / 10^4

    absolute_k_area = vec(total_site_area' .* max_cover)  # max possible coral area in m^2
    growth::ODEProblem = ODEProblem{true,false}(growthODE, Y_cover[1, :, :], tspan, p)
    @inbounds for tstep::Int64 in 2:tf
        p_step = tstep - 1
        Y_tmp_cover[:, :] .= Y_cover[p_step, :, :]

        sf .= stressed_fecundity(tstep, a_adapt, n_adapt, dhw_scen[p_step, :],
                                 LPdhwcoeff, DHWmaxtot, LPDprm2, n_groups)

        # Calculates scope for coral fedundity for each size class and at each site.
        # fecundity_scope!(fec_scope, fec_all, fec_params, Y_tmp_cover, total_site_area)
        suitable_substratum = sum(Y_tmp_cover, dims=1) .* total_site_area
        fecundity_scope!(fec_scope, fec_all, fec_params, Y_tmp_cover, suitable_substratum)

        # Send larvae out into the world
        actual_fecundity = (fec_scope .* sf)
        larval_pool = (actual_fecundity * TP_data)  # larval pool for each site (in larvae/m²)

        site_coral_cover = vec(sum(Y_tmp_cover, dims=1))
        absolute_site_coral_cover = site_coral_cover' .* total_site_area  # in m²
        leftover_space = max.(absolute_k_area' .- absolute_site_coral_cover, 0.0)

        # Larvae have landed, work out how many are recruited
        r_rate = recruitment_rate(larval_pool, leftover_space) ./ absolute_k_area'  # convert to m²
        r_rate = replace(replace(r_rate, NaN=>0.0), Inf=>0.0)  # remove division by 0 error
        λ = min.(r_rate, sim_params.max_settler_density)

        # Determine area covered by recruited larvae
        settler_cover = λ .* sim_params.basal_area_per_settler
        adj_rec = settler_cover .* max.(max_cover .- site_coral_cover, 0.0)'

        # Recruitment should represent additional cover, relative to total site area
        # Gets added to Y_cover in ODE
        @views p.rec[:, :] .= adj_rec
        @views dhw_step .= dhw_scen[tstep, :]  # subset of DHW for given timestep

        in_shade_years = (shade_start_year <= tstep) && (tstep <= (shade_start_year + shade_years - 1))
        in_seed_years = ((seed_start_year <= tstep) && (tstep <= (seed_start_year + seed_years - 1)))
        if is_guided && in_seed_years
            # Update dMCDA values
            mcda_vars.damprob .= @view mwaves[tstep, :, :]
            mcda_vars.heatstressprob .= dhw_step

            mcda_vars.sumcover .= sum(Y_tmp_cover, dims=1)  # dims: nsites * 1

            (prefseedsites, prefshadesites, rankings) = dMCDA(mcda_vars, MCDA_approach,
                                                              seed_decision_years[tstep], shade_decision_years[tstep],
                                                              prefseedsites, prefshadesites, rankings)

            # Log site ranks
            # First col only holds site ids so skip (with 2:end)
            site_ranks[tstep, rankings[:, 1], :] = rankings[:, 2:end]
        else
            if seed_corals && in_seed_years
                # Unguided deployment, seed/shade corals anywhere, so long as available space > 0
                available_space = vec(max.(max_cover' .- sum(Y_tmp_cover, dims=1), 0.0))
                prefseedsites, prefshadesites = unguided_site_selection(prefseedsites, prefshadesites,
                                                                        seed_decision_years[tstep], shade_decision_years[tstep],
                                                                        nsiteint, available_space)
            end
        end

        has_shade_sites = !all(prefshadesites .== 0)
        has_seed_sites = !all(prefseedsites .== 0)
        if (srm > 0.0) && in_shade_years
            Yshade[tstep, :] .= srm

            # Apply reduction in DHW due to shading
            adjusted_dhw::Vector{Float64} = max.(0.0, dhw_step .- srm)
        else
            adjusted_dhw = dhw_step
        end

        if (fogging > 0.0) && in_shade_years && (has_seed_sites || has_shade_sites)
            if has_seed_sites
                # Always fog where sites are selected if possible
                site_locs::Vector{Int64} = prefseedsites
            elseif has_shade_sites
                # Otherwise, if no sites are selected, fog selected shade sites
                site_locs = prefshadesites
            end

            adjusted_dhw[site_locs] .= adjusted_dhw[site_locs] .* (1.0 - fogging)
            Yfog[tstep, site_locs] .= fogging
        end

        # Calculate and apply bleaching mortality
        bleaching_mortality!(Sbl, tstep, neg_e_p1, neg_e_p2,
                             a_adapt, n_adapt,
                             bleach_resist, adjusted_dhw)

        # Apply seeding
        if seed_corals && in_seed_years && has_seed_sites
            # Extract site area for selected sites
            site_area_seed = total_site_area[prefseedsites]

            # Determine area (m^2) to be covered by seeded corals
            # and make relative to total site
            scaled_seed_TA = ((n_TA_to_seed / nsiteint) * col_area_seed_TA) ./ site_area_seed
            scaled_seed_CA = ((n_CA_to_seed / nsiteint) * col_area_seed_CA) ./ site_area_seed

            # Seed each site with the value indicated with seed1/seed2
            @views Y_tmp_cover[seed_sc_TA, prefseedsites] .= Y_tmp_cover[seed_sc_TA, prefseedsites] .+ scaled_seed_TA
            @views Y_tmp_cover[seed_sc_CA, prefseedsites] .= Y_tmp_cover[seed_sc_CA, prefseedsites] .+ scaled_seed_CA

            # Log seed values/sites (these values are relative to site area)
            Yseed[tstep, 1, prefseedsites] .= scaled_seed_TA
            Yseed[tstep, 2, prefseedsites] .= scaled_seed_CA
        end

        @views prop_loss = Sbl[:, :] .* Sw_t[p_step, :, :]
        growth.u0[:, :] .= Y_tmp_cover[:, :] .* prop_loss[:, :]  # update initial condition
        sol::ODESolution = solve(growth, solver, save_everystep=false, save_start=false,
                                 alg_hints=[:nonstiff], abstol=1e-9, reltol=1e-8)  # , adaptive=false, dt=1.0
        # Using the last step from ODE above, proportionally adjust site coral cover
        # if any are above the maximum possible (i.e., the site `k` value)
        Y_cover[tstep, :, :] .= proportional_adjustment!(sol.u[end], cover_tmp, max_cover)

        # growth::ODEProblem = ODEProblem{true,false}(growthODE, cov_tmp .* prop_loss[:, :], tspan, p)
        # sol::ODESolution = solve(growth, solver, abstol=1e-7, reltol=1e-4, save_everystep=false, save_start=false, alg_hints=[:nonstiff])
        # Yout[tstep, :, :] .= sol.u[end]
        # Yout[tstep, :, :] .= proportional_adjustment!(Yout[tstep, :, :], cover_tmp, max_cover)
    end

    # Avoid placing importance on sites that were not considered
    # (lower values are higher importance)
    site_ranks[site_ranks .== 0.0] .= n_sites + 1

    return (raw=Y_cover, seed_log=Yseed, fog_log=Yfog, shade_log=Yshade, site_ranks=site_ranks)
end
