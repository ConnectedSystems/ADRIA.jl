using JSON


"""
    _check_compat(dpkg_details::Dict)

Checks for version compatibility.

# Arguments
- dpkg_details : Datapackage spec
"""
function _check_compat(dpkg_details::Dict)
    if haskey(dpkg_details, "version") || haskey(dpkg_details, "dpkg_version")
        dpkg_version = dpkg_details["version"]
        if dpkg_version ∉ COMPAT_DPKG
            error("Incompatible Domain data package.")
        end
    else
        error("Incompatible Domain data package.")
    end
end

"""
    _load_dpkg(dpkg_path::String)

Load and parse datapackage.

# Arguments
- dpkg_path : path to datapackage
"""
function _load_dpkg(dpkg_path::String)
    dpkg_md = nothing
    open(joinpath(dpkg_path, "datapackage.json"), "r") do fp
        dpkg_md = JSON.parse(read(fp, String))
    end
    _check_compat(dpkg_md)

    return dpkg_md
end

"""
    load_domain(path::String, rcp::Int64)
    load_domain(path::String, rcp::String)
    load_domain(path::String)

Load domain specification from data package.

# Arguments
- path : location of data package
- rcp : RCP scenario to run. If none provided, no data path is set.
"""
function load_domain(path::String, rcp::String)::Domain
    domain_name::String = basename(path)
    if length(domain_name) == 0
        domain_name = basename(dirname(path))
    end

    dpkg_details = _load_dpkg(path)
    dpkg_version = dpkg_details["version"]

    # Handle compatibility
    this_version = parse(VersionNumber, dpkg_version)
    if this_version >= v"0.2.1"
        # Extract the time frame represented in this data package
        timeframe = dpkg_details["simulation_metadata"]["timeframe"]
    else
        # Default to 2025-2099
        timeframe = (2025, 2099)
    end

    if length(timeframe) == 2
        @assert timeframe[1] < timeframe[2] "Start date/year specified in data package must be < end date/year"
        # If only two elements, assume a range is specified.
        # Collate the time steps as a full list if necessary
        timeframe = collect(timeframe[1]:timeframe[2])
    end

    conn_path::String = joinpath(path, "connectivity/")
    site_data::String = joinpath(path, "site_data")

    site_path::String = joinpath(site_data, "$(domain_name).gpkg")
    init_coral_cov::String = joinpath(site_data, "coral_cover.nc")

    if !isempty(rcp)
        dhw::String = joinpath(path, "DHWs", "dhwRCP$(rcp).nc")
        wave::String = joinpath(path, "waves", "wave_RCP$(rcp).nc")
    else
        dhw = ""
        wave = ""
    end

    return Domain(
        domain_name,
        path,
        rcp,
        timeframe,
        site_path,
        "site_id",
        "reef_siteid",
        init_coral_cov,
        conn_path,
        dhw,
        wave
    )
end
function load_domain(path::String, rcp::Int)::Domain
    return load_domain(path, "$rcp")
end
function load_domain(path::String)::Domain
    return load_domain(path, "")
end


"""
    load_scenarios(domain::Domain, filepath::String)::DataFrame

Load and pre-process scenario values.
Parameters intended to be of Integer type or casted as such.
"""
function load_scenarios(domain::Domain, filepath::String)::DataFrame
    df = CSV.read(filepath, DataFrame, comment="#")

    if "RCP" in names(df) || :RCP in names(df)
        df = df[!, Not("RCP")]
    end
    process_inputs!(domain, df)

    return df
end

function process_inputs!(d::Domain, df::DataFrame)
    bnds = d.model[:bounds]
    p_types = d.model[:ptype]
    @inbounds for (i, dt) in enumerate(p_types)
        if dt == "integer"
            df[!, i] .= map_to_discrete.(df[!, i], bnds[i][2])
        end
    end
end

function load_mat_data(data_fn::String, attr::String, site_data::DataFrame)::NamedArray
    data = matread(data_fn)
    local loaded::NamedArray
    local site_order::Vector{String}

    try
        site_order = Vector{String}(vec(data["reef_siteid"]))
        loaded = NamedArray(data[attr])
    catch err
        if isa(err, KeyError)
            @warn "Provided file $(data_fn) did not have reef_siteid! There may be a mismatch in sites."
            if size(loaded, 2) != nrow(site_data)
                @warn "Mismatch in number of sites ($(data_fn)).\nTruncating so that data size matches!"

                # Subset down to number of sites
                loaded = selectdim(data[attr], 2, 1:nrow(site_data))
            end
        else
            rethrow(err)
        end
    end

    # Attach site names to each column
    setnames!(loaded, site_order, 2)
    setdimnames!(loaded, "Source", 1)
    setdimnames!(loaded, "Receiving", 2)

    # Reorder sites so they match with spatial data
    loaded = selectdim(loaded, 2, site_order)

    return loaded
end


"""
    load_nc_data(data_fn::String, attr::String, n_sites::Int)::NamedArray

Load netCDF data as a NamedArray.
"""
function load_nc_data(data_fn::String, attr::String, site_data::DataFrame)::NamedArray
    local loaded::NamedArray

    ds = Dataset(data_fn, "r")
    data = ds[attr][:, :]
    close(ds)

    try
        loaded = NamedArray(data)
    catch err
        if isa(err, KeyError)
            n_sites = size(data, 2)
            @warn "Provided file $(data_fn) did not have the expected dimensions (one of: timesteps, reef_siteid, members)."
            if n_sites != nrow(site_data)
                error("Mismatch in number of sites ($(data_fn)). Expected $(nrow(site_data)), got $(n_sites)")
            end
        else
            rethrow(err)
        end
    end

    return loaded
end

"""
    _char_to_string(vals)::Vector{String}

Convert character array entries in netCDFs to string.
"""
function _char_to_string(vals)::Vector{String}
    if vals isa Matrix
        vals = map(x -> join(skipmissing(x)), eachcol(vals))
    end

    # R's ncdf4 package does not yet support string values
    # so strip the null terminator from the joined character array.
    vals = replace.(vals, "\0" => "")

    return vals
end


"""
    load_covers(data_fn::String, attr::String, site_data::DataFrame)::NamedArray

Load initial coral cover data from netCDF.
"""
function load_covers(data_fn::String, attr::String, site_data::DataFrame)::NamedArray
    data = load_nc_data(data_fn, attr, site_data)

    ds = Dataset(data_fn, "r")
    site_order = string.(ds["reef_siteid"][:])
    close(ds)

    site_order = _char_to_string(site_order)

    # Attach site names to each column
    setnames!(data, site_order, 2)
    setdimnames!(data, :species, 1)
    setdimnames!(data, :sites, 2)

    # Reorder sites for alignment
    data = data[:, site_data.reef_siteid]

    return data
end


"""
    load_env_data(data_fn::String, attr::String, site_data::DataFrame)::NamedArray

Load environmental data layers (DHW, Wave) from netCDF.
"""
function load_env_data(data_fn::String, attr::String, site_data::DataFrame)::NamedArray
    data = load_nc_data(data_fn, attr, site_data)

    ds = Dataset(data_fn, "r")
    site_order = string.(ds["reef_siteid"][:])
    close(ds)

    site_order = _char_to_string(site_order)

    # Attach dimension names
    setnames!(data, site_order, 2)
    setdimnames!(data, :timesteps, 1)
    setdimnames!(data, :sites, 2)
    setdimnames!(data, :scenarios, 3)

    # Reorder sites so they align
    data = data[:, site_data.reef_siteid, :]

    return data
end
