defmodule ExDoc.Formatter.EPUB do
  @moduledoc """
  Provide EPUB documentation
  """

  alias ExDoc.Formatter.HTML
  alias ExDoc.Formatter.EPUB.Templates

  @doc """
  Generate EPUB documentation for the given modules
  """
  @spec run(list, %ExDoc.Config{}) :: String.t
  def run(module_nodes, config) when is_map(config) do
    output = Path.expand(config.output)
    File.rm_rf!(output)
    File.mkdir_p!("#{output}/OEBPS/modules")

    assets |> templates_path() |> HTML.generate_assets(output)

    all = HTML.Autolink.all(module_nodes)
    modules = HTML.filter_list(:modules, all)
    exceptions = HTML.filter_list(:exceptions, all)
    protocols = HTML.filter_list(:protocols, all)

    if config.logo do
      config = HTML.process_logo_metadata(config, "#{config.output}/OEBPS/assets")
    end

    generate_mimetype(output)
    generate_extras(output, config, module_nodes)

    uuid = "urn:uuid:#{uuid4()}"
    datetime = format_datetime()
    generate_content(output, config, modules, exceptions, protocols, uuid, datetime)
    generate_toc(output, config, modules, exceptions, protocols, uuid)
    generate_nav(output, config, modules, exceptions, protocols)
    generate_title(output, config)
    generate_list(output, config, modules)
    generate_list(output, config, exceptions)
    generate_list(output, config, protocols)

    {:ok, epub_file} = generate_epub(output, config)
    delete_extras(output)

    epub_file
  end

  defp generate_mimetype(output) do
    content = "application/epub+zip"
    File.write("#{output}/mimetype", content)
  end

  defp generate_extras(output, config, module_nodes) do
    config.extras
    |> Enum.map(&Task.async(fn -> generate_extra(&1, output, config, module_nodes) end))
    |> Enum.map(&Task.await/1)
  end

  defp generate_extra(input, output, config, module_nodes) do
    file_ext =
      input
      |> Path.extname()
      |> String.downcase()

    if file_ext in [".md"] do
      file_name =
        input
        |> Path.basename(".md")
        |> String.upcase()

      content =
        input
        |> File.read!()
        |> HTML.Autolink.project_doc(module_nodes)

      config = Map.put(config, :title, file_name)
      extra_html =
        config
        |> Templates.extra_template(content)
        |> valid_xhtml_ids()

      File.write!("#{output}/OEBPS/modules/#{file_name}.html", extra_html)
    else
      raise ArgumentError, "file format not recognized, allowed format is: .md"
    end
  end

  defp generate_content(output, config, modules, exceptions, protocols, uuid, datetime) do
    content = Templates.content_template(config, modules ++ exceptions ++ protocols, uuid, datetime)
    File.write("#{output}/OEBPS/content.opf", content)
  end

  defp generate_toc(output, config, modules, exceptions, protocols, uuid) do
    content = Templates.toc_template(config, modules ++ exceptions ++ protocols, uuid)
    File.write("#{output}/OEBPS/toc.ncx", content)
  end

  defp generate_nav(output, config, modules, exceptions, protocols) do
    content = Templates.nav_template(config, modules ++ exceptions ++ protocols)
    File.write("#{output}/OEBPS/nav.html", content)
  end

  defp generate_title(output, config) do
    content = Templates.title_template(config)
    File.write("#{output}/OEBPS/title.html", content)
  end

  defp generate_list(output, config, nodes) do
    nodes
    |> Enum.map(&Task.async(fn -> generate_module_page(output, config, &1) end))
    |> Enum.map(&Task.await/1)
  end

  defp generate_epub(output, config) do
    output = Path.expand(output)
    target_path =
      "#{output}/#{config.project}-v#{config.version}.epub"
      |> String.to_char_list()

    {:ok, zip_path} = :zip.create(target_path,
                                  files_to_add(output),
                                  compress: ['.css', '.html', '.ncx', '.opf',
                                             '.jpg', '.png', '.xml'])
    {:ok, zip_path}
  end

  defp delete_extras(output) do
    for target <- ["META-INF", "mimetype", "OEBPS"] do
      File.rm_rf! "#{output}/#{target}"
    end
    :ok
  end

  ## Helpers

  defp assets do
   [
     {"css/*.css", "OEBPS/css" },
     {"assets/*.xml", "META-INF" },
     {"assets/mimetype", "." }
   ]
  end

  defp files_to_add(path) do
    File.cd! path, fn ->
      meta = Path.wildcard("META-INF/*")
      oebps = Path.wildcard("OEBPS/**/*")

      Enum.reduce meta ++ oebps ++ ["mimetype"], [], fn(f, acc) ->
        case File.read(f) do
          {:ok, bin} ->
            [{f |> String.to_char_list, bin}|acc]
          {:error, _} ->
            acc
        end
      end
    end
  end

  # Helper to format Erlang datetime tuple
  defp format_datetime do
    {{year, month, day}, {hour, min, sec}} = :calendar.universal_time()
    list = [year, month, day, hour, min, sec]
    "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ"
    |> :io_lib.format(list)
    |> IO.iodata_to_binary()
  end

  defp generate_module_page(output, config, node) do
    content =
      config
      |> Templates.module_page(node)
      |> valid_xhtml_ids()
    File.write("#{output}/OEBPS/modules/#{node.id}.html", content)
  end

  defp href(%URI{fragment: nil} = link), do: to_string link
  defp href(%URI{fragment: fragment} = link) do
    fragment =
      fragment
      |> id_replace()

    link
    |> struct([fragment: fragment])
    |> to_string()
  end

  defp id_replace(id) do
    pattern = ~r/[^A-Za-z0-9_.-]/
    replacement = "--"

    String.replace(id, pattern, replacement)
  end

  defp new_id(id), do: ~s(id="#{id}")

  defp new_href(link), do: ~s(href="#{href link}")

  defp templates_path(patterns) do
    Enum.into(patterns, [], fn {pattern, dir} ->
      {Path.expand("epub/templates/#{pattern}", __DIR__), dir}
    end)
  end

  # Helper to generate an UUID v4. This version uses pseudo-random bytes generated by
  # the `crypto` module.
  defp uuid4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.rand_bytes(16)
    bin = <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = bin

    Enum.map_join([<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>], <<45>>,
                  &(Base.encode16(&1, case: :lower)))
  end

  defp valid_xhtml_ids(content) do
    content = Regex.replace(~r/href=\s*"(?!(http|https|ftp|mailto|irc):\/\/)([^"]+)"/i,
                            content,
                            fn _, _, link ->
                              link
                              |> URI.parse
                              |> new_href
                            end)

    Regex.replace(~r/id="([^\"]+)"/,
                  content,
                  fn _, id ->
                    id
                    |> id_replace
                    |> new_id
                  end)
  end
end
