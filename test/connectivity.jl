using ADRIA, DataFrames, CSV
import GeoDataFrames as GDF
using CSV


@testset "Connectivity loading" begin
    site_data = GDF.read(joinpath(@__DIR__, "..", "examples", "Example_domain", "site_data", "Example_domain.gpkg"))
    sort!(site_data, [:reef_siteid])

    unique_site_ids = site_data.reef_siteid
    conn_files = joinpath(@__DIR__, "..", "examples", "Example_domain", "connectivity")
    conn_data = CSV.read(joinpath(conn_files, "2000", "test_conn_data.csv"), DataFrame, comment="#", drop=[1], types=Float64)

    conn_details = ADRIA.site_connectivity(conn_files, unique_site_ids)

    TP_data = conn_details.TP_base
    @test all(names(TP_data, 2) .== site_data.reef_siteid) || "Sites do not match expected order!"
end
