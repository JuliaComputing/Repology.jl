module ExportTests
using Test
include("../scripts/update_repology_info.jl")

function fixture()
    DataFrame(link_type=Int8[1,2,1,1],repo=["a","a","b","c"],effname=["source","source","wrapper","other"],
        rawversion=fill("1.0",4),arch=fill(missing,4),origversion=fill("1.0",4),
        url=["https://example.org/source-1.0.tar.gz","https://example.org/source.git",
             "http://example.org/source-1.0.tar.xz","https://example.org/other-1.0.tar.gz"])
end

@testset "global-family export" begin
    df=fixture();counts=Dict("source"=>5,"wrapper"=>1,"other"=>2)
    d,r,resolved=gather_links(df,counts)
    @test d[df.url[1]]==("source"=>"1.0")
    @test d[df.url[3]]==("source"=>"1.0")
    @test d[df.url[4]]==("other"=>"1.0")
    @test !haskey(r,df.url[2])
    @test resolved[Repology.normalize_url(df.url[1])]=="source"
    @test !haskey(first(gather_links(df,merge(counts,Dict("wrapper"=>5)))),df.url[1])
    near=merge(counts,Dict("wrapper"=>4))
    @test !haskey(first(gather_links(df,near)),df.url[1])
    @test first(gather_links(df,near;minimum_margin=1))[df.url[1]]==("source"=>"1.0")
    @test !haskey(first(gather_links(df,counts;minimum_margin=5)),df.url[1])
    @test_throws ArgumentError gather_links(df,counts;minimum_margin=0)
    @test all(isempty,gather_links(df[1:0,:],counts))
    old=Dict("ftp://example.org/source-1.0.tar.bz2"=>("wrapper"=>"1.0"),"https://old.org/old-2.0.tar.gz"=>("old"=>"2.0"))
    retargeted=retarget_history(old,resolved;downloads=true)
    @test retargeted["ftp://example.org/source-1.0.tar.bz2"]==("source"=>"1.0")
    @test retargeted["https://old.org/old-2.0.tar.gz"]==("old"=>"2.0")
    @test retarget_history(Dict(df.url[1]=>"wrapper"),resolved)[df.url[1]]=="source"
    @test retarget_history(old,Dict{String,String}();downloads=true)==old
    repos=df[[1,3],:]
    repos.link_type .= 2
    repos.url=["https://example.org/source.git","http://example.org/source.git"]
    rd,rr,_=gather_links(repos,counts)
    @test isempty(rd)
    @test rr==Dict(url=>"source" for url in repos.url)
    df.origversion[1]="unreleased"
    @test !haskey(first(gather_links(df,counts)),df.url[1])
end

@testset "whole-dump family counts" begin
    sql="COPY repology.links (id, url) FROM stdin;\n\\.\n" *
        "COPY repology.packages (effname, family, cpe_vendor, cpe_product, repo, arch, rawversion, origversion, links) FROM stdin;\n" *
        "source\tfamily-a\t\\N\t\\N\trepo-a\t\\N\t1.0\t1.0\t[]\n" *
        "source\tfamily-a\t\\N\t\\N\trepo-b\t\\N\t1.1\t1.1\t[]\n" *
        "source\tfamily-b\t\\N\t\\N\trepo-c\t\\N\t1.0\t1.0\t[]\n\\.\n"
    df,_,_,counts=read_dump(IOBuffer(sql))
    @test nrow(df)==0
    @test counts==Dict("source"=>2)
    _,_,_,empty_counts=read_dump(IOBuffer(""))
    @test isempty(empty_counts)
    @test_throws ArgumentError read_dump(IOBuffer("COPY repology.links (id, url) FROM stdin;\nbad\thttps://example.org\n\\.\n"))
end
end
