module BitemporalReactive
using BitemporalPostgres, JSON, Logging, SearchLight, Stipple, StippleUI, TimeZones, ToStruct
using LifeInsuranceDataModel
using LifeInsuranceProduct
include("ContractSectionView.jl")
using .ContractSectionView
include("PartnerSectionView.jl")
using .PartnerSectionView
"""
compareRevisions(t, previous::Dict{String,Any}, current::Dict{String,Any}) where {T<:BitemporalPostgres.ComponentRevision}
compare corresponding revision elements and return nothing if equal a pair of both else
"""
function compareRevisions(t, previous::Dict{String,Any}, current::Dict{String,Any})
    let changed = false
        for (key, previous_value) in previous
            if !(key in ("ref_validfrom", "ref_invalidfrom", "ref_component"))
                let current_value = current[key]
                    if previous_value != current_value
                        changed = true
                    end
                end
            end
        end
        if (changed)
            (ToStruct.tostruct(t, previous), ToStruct.tostruct(t, current))
        end
    end
end
"""
compareModelStateContract(previous::Dict{String,Any}, current::Dict{String,Any})
	compare viewmodel state for a contract section
"""
function compareModelStateContract(previous::Dict{String,Any}, current::Dict{String,Any})
    diff = []
    cr = compareRevisions(ContractRevision, previous["revision"], current["revision"])
    if (!isnothing(cr))
        push!(diff, cr)
    end
    for i in 1:size(previous["partner_refs"])[1]
        prev = (previous["partner_refs"][i]["rev"])
        curr = (current["partner_refs"][i]["rev"])
        prr = compareRevisions(ContractPartnerRefRevision, prev, curr)
        if (!isnothing(prr))
            push!(diff, prr)
        end

    end
    for i in 1:size(previous["product_items"])[1]
        prevpi = previous["product_items"][i]
        currpi = current["product_items"][i]
        pit = compareRevisions(ProductItemRevision, prevpi["revision"], currpi["revision"])
        if (!isnothing(pit))
            push!(diff, pit)
        end
        for i in 1:size(prevpi["tariff_items"])[1]
            prevti = prevpi["tariff_items"][i]
            currti = currpi["tariff_items"][i]
            tit = compareRevisions(TariffItemRevision, prevti["tariff_ref"]["rev"], currti["tariff_ref"]["rev"])
            if (!isnothing(tit))
                push!(diff, tit)
            end
            for i in 1:size(prevti["partner_refs"])[1]
                prevtipr = prevti["partner_refs"][i]["rev"]
                currtipr = currti["partner_refs"][i]["rev"]
                tiprt = compareRevisions(TariffItemPartnerRefRevision, prevtipr, currtipr)
                if (!isnoting(tiprt))
                    push!(diff, tiprt)
                end
            end
        end
    end
    diff
end

"""
Activetxn
	whether a transaction/workflow is active
"""
Activetxn = 0


"""
load_roles(contractsModel)

	loads role tables, that provide texts for integer role keys
"""
function load_roles(contractsModel)
    map(find(LifeInsuranceDataModel.ContractPartnerRole)) do entry
        contractsModel.rolesContractPartner[entry.id.value] = entry.value
    end
    println(contractsModel.rolesContractPartner)


    map(find(LifeInsuranceDataModel.TariffItemRole)) do entry
        contractsModel.rolesTariffItem[entry.id.value] = entry.value
    end

    map(find(LifeInsuranceDataModel.TariffItemPartnerRole)) do entry
        contractsModel.rolesTariffItemPartner[entry.id.value] = entry.value
    end

end

"""
convert(node::BitemporalPostgres.Node)::Dict{String,Any}

provides the view for the history forest from tree data the contracts/partnersModel delivers
"""
function convert(node::BitemporalPostgres.Node)::Dict{String,Any}
    i = Dict(string(fn) => getfield(getfield(node, :interval), fn) for fn in fieldnames(ValidityInterval))
    shdw = length(node.shadowed) == 0 ? [] : map(node.shadowed) do child
        convert(child)
    end
    Dict("label" => string(i["ref_version"]), "interval" => i, "children" => shdw, "time_committed" => string(i["tsdb_validfrom"]), "time_valid_asof" => string(i["tsworld_validfrom"]))
end

"""
fn
retrieves a history node from its label 
"""

function fn(ns::Vector{Dict{String,Any}}, lbl::String)
    for n in ns
        if (n["label"] == lbl)
            return (n)
        else
            if (length(n["children"]) > 0)
                m = fn(n["children"], lbl)
                if !isnothing(typeof(m))
                    return m
                end
            end
        end
    end
end

"""
handlers(contractsModel::ContractSectionView.ContractsModel)

Event handling and synching of the view contractsModel between UI and contractsModel server
"""
function handlers(contractsModel::ContractSectionView.ContractsModel)

    on(contractsModel.isready) do _
        contractsModel.contracts = LifeInsuranceDataModel.get_contracts()
        contractsModel.tab[] = "contracts"
        contractsModel.cs["loaded"] = "false"
        load_roles(contractsModel)
        push!(contractsModel)
        println("contractsModel pushed")
    end

    on(contractsModel.command) do _
        @info "command= " * contractsModel.command[]
        if (contractsModel.command[] != "")
            @info "command= " * contractsModel.command[] * " desc= " * contractsModel.cs["revision"]["description"]
            contractsModel.command[] = ""
        end
    end

    on(contractsModel.selected_version) do _
        @info "selected version" * contractsModel.selected_version[]
        if (contractsModel.selected_version[] != "")
            try
                node = fn(contractsModel.histo, contractsModel.selected_version[])
                contractsModel.txn_time = node["interval"]["tsdb_validfrom"]
                contractsModel.ref_time = node["interval"]["tsworld_validfrom"]
                contractsModel.current_version = parse(Int, contractsModel.selected_version[])
                println(contractsModel.txn_time)
                println(contractsModel.ref_time)
                println(contractsModel.current_version)
                @info "vor csection"
                contractsModel.cs = JSON.parse(JSON.json(LifeInsuranceDataModel.csection(contractsModel.current_contract.id.value, contractsModel.txn_time, contractsModel.ref_time)))
                contractsModel.cs["loaded"] = "true"
                @info "vor tab "
                contractsModel.tab = "csection"
                # ti = LifeInsuranceProduct.calculate!(contractsModel.cs["product_items"][1].tariff_items[1])
                ti = contractsModel.cs["product_items"][1]
                print("ti=")
                println(ti)
                push!(contractsModel)
            catch err
                println("wassis shief gegangen ")
                @error "ERROR: " exception = (err, catch_backtrace())
            end

        end
    end

    on(contractsModel.selected_contract_idx) do _
        @info "enter selected_contract_idx"
        if (contractsModel.selected_contract_idx[] >= 0)
            try
                println(contractsModel.selected_contract_idx[])
                println(contractsModel.contracts[contractsModel.selected_contract_idx[]+1])
                contractsModel.current_contract = contractsModel.contracts[contractsModel.selected_contract_idx[]+1]
                contractsModel.histo = map(convert, LifeInsuranceDataModel.history_forest(contractsModel.current_contract.ref_history.value).shadowed)
                contractsModel.cs = JSON.parse(JSON.json(LifeInsuranceDataModel.csection(contractsModel.current_contract.id.value, now(tz"Europe/Warsaw"), now(tz"Europe/Warsaw"), contractsModel.activetxn)))
                contractsModel.cs["loaded"] = "true"
                ti = contractsModel.cs["product_items"][1]["tariff_items"][1]
                print("ti=")
                println(ti)
                print("tistruct")
                println(ToStruct.tostruct(LifeInsuranceDataModel.TariffItemSection, ti))
                tistruct = ToStruct.tostruct(LifeInsuranceDataModel.TariffItemSection, ti)
                LifeInsuranceProduct.calculate!(tistruct)
                contractsModel.cs["product_items"][1]["tariff_items"][1] = JSON.parse(JSON.json(tistruct))
                contractsModel.selected_contract_idx[] = -1
                contractsModel.tab = "csection"
                push!(contractsModel)
            catch err
                println("wassis shief gegangen ")
                @error "ERROR: " exception = (err, catch_backtrace())
            end
        end

    end

    on(contractsModel.selected_product) do _
        println("contractsModel selected ")
        println(contractsModel.selected_product[])
        if (contractsModel.selected_product[] > 0)
            contractsModel.tab[] = "product"
            contractsModel.prs = JSON.parse(JSON.json(LifeInsuranceDataModel.prsection(contractsModel.selected_product[], now(tz"UTC"), now(tz"UTC"))))
            contractsModel.selected_product[] = 0
            contractsModel.prs["loaded"] = "true"
        end
        push!(contractsModel)
    end

    on(contractsModel.tab) do _
        println(contractsModel.tab[])
        #       if (contractsModel.tab[] == "contracts")
        #            contractsModel.selected_contract_idx = -1
        #        end
        if (contractsModel.tab[] == "history")
            println("current contract")
            println(contractsModel.current_contract)
            contractsModel.histo = map(convert, LifeInsuranceDataModel.history_forest(contractsModel.current_contract.ref_history.value).shadowed)
            push!(contractsModel)
            println("MODEL pushed")
        end
    end

    contractsModel
end
"""
handlers(cpartnersModel::PartnerSectionView.PartnersModel)

Event handling and synching of the view PartnersModel between UI and partnersModel server
"""

function handlers(partnersModel::PartnerSectionView.PartnersModel)
    on(partnersModel.isready) do _
        partnersModel.partners = LifeInsuranceDataModel.get_partners()
        partnersModel.tab[] = "partners"
        push!(partnersModel)
        println("partnersModel pushed")
    end

    on(partnersModel.selected_partner_idx) do _
        println(partnersModel.selected_partner_idx[])
        println(partnersModel.partners[partnersModel.selected_partner_idx[]+1])
        partnersModel.current_partner[] = partnersModel.partners[partnersModel.selected_partner_idx[]+1]
        partnersModel.histo = map(convert, LifeInsuranceDataModel.history_forest(partnersModel.current_partner[].ref_history.value).shadowed)
        partnersModel.ps = JSON.parse(JSON.json(LifeInsuranceDataModel.psection(partnersModel.current_partner[].id.value, now(tz"Europe/Warsaw"), now(tz"Europe/Warsaw"))))
        partnersModel.ps["loaded"] = "true"
        partnersModel.tab[] = "psection"
        println("partner selected to psection")
        push!(partnersModel)

    end

    on(partnersModel.selected_version) do _
        println("selected version")
        println(partnersModel.selected_version[])
        if (partnersModel.selected_version[] != "")
            node = fn(partnersModel.histo[], partnersModel.selected_version[])
            partnersModel.txn_time = node["interval"]["tsdb_validfrom"]
            partnersModel.ref_time = node["interval"]["tsworld_validfrom"]
            partnersModel.current_version = parse(Int, partnersModel.selected_version[])
            println(partnersModel.txn_time)
            println(partnersModel.ref_time)
            println(partnersModel.current_version)
            partnersModel.ref_time[]
            partnersModel.ps = JSON.parse(JSON.json(LifeInsuranceDataModel.psection(partnersModel.current_partner.id.value, partnersModel.txn_time[], partnersModel.ref_time[])))
            partnersModel.ps["loaded"] = "true"
            partnersModel.tab = "psection"
            push!(partnersModel)
        end
    end

    partnersModel
end

"""
run

creating the route
"""
function run(async::Bool=false)
    contractsModel = handlers(Stipple.init(ContractSectionView.ContractsModel))
    route("/ContractSection") do
        Activetxn = params(:activetxn, "0")
        println("from session " * Activetxn)
        contractsModel.activetxn = parse(Int64, Activetxn)
        println("contractsModel.activetxn " * string(contractsModel.activetxn))
        println(params)
        html(ContractSectionView.ui(contractsModel), context=@__MODULE__)
    end

    route("/") do
        redirect("/ContractSection")
    end

    partnersModel = handlers(PartnerSectionView.PartnersModel |> init)

    route("/PartnerSection") do
        html(PartnerSectionView.ui(partnersModel), context=@__MODULE__)
    end


    Stipple.up(async=async)
end

end

