local config = require('overleaf.config')

local M = {}

M._projects = {}
M._project_tree = {} -- flat list of {id, name, path}

function M.set_projects(projects)
  M._projects = projects or {}
end

function M.select_project(callback)
  if #M._projects == 0 then
    config.log('warn', 'No projects available')
    return
  end

  local items = {}
  for _, p in ipairs(M._projects) do
    table.insert(items, {
      label = p.name,
      id = p.id,
      detail = p.accessLevel or '',
    })
  end

  vim.ui.select(items, {
    prompt = 'Select Overleaf Project:',
    format_item = function(item)
      return item.label .. ' (' .. item.detail .. ')'
    end,
  }, function(choice)
    if choice then
      callback(choice.id, choice.label)
    end
  end)
end

function M.parse_project_tree(project)
  M._project_tree = {}
  if not project or not project.rootFolder then
    return M._project_tree
  end

  local root = project.rootFolder
  if type(root) == 'table' and root[1] then
    root = root[1]
  end

  M._walk_folder(root, '')
  return M._project_tree
end

function M._walk_folder(folder, prefix, depth)
  depth = depth or 0

  -- Process subfolders first (for tree display order)
  if folder.folders then
    for _, subfolder in ipairs(folder.folders) do
      local subpath = prefix .. subfolder.name .. '/'
      table.insert(M._project_tree, {
        id = subfolder._id,
        name = subfolder.name,
        path = subpath,
        type = 'folder',
        depth = depth,
      })
      M._walk_folder(subfolder, subpath, depth + 1)
    end
  end

  -- Process docs (text files)
  if folder.docs then
    for _, doc in ipairs(folder.docs) do
      table.insert(M._project_tree, {
        id = doc._id,
        name = doc.name,
        path = prefix .. doc.name,
        type = 'doc',
        depth = depth,
      })
    end
  end

  -- Process file refs (binary files)
  if folder.fileRefs then
    for _, file in ipairs(folder.fileRefs) do
      table.insert(M._project_tree, {
        id = file._id,
        name = file.name,
        path = prefix .. file.name,
        type = 'file',
        depth = depth,
      })
    end
  end
end

function M.select_document(callback)
  if #M._project_tree == 0 then
    config.log('warn', 'No documents in project')
    return
  end

  vim.ui.select(M._project_tree, {
    prompt = 'Select Document:',
    format_item = function(item)
      return item.path
    end,
  }, function(choice)
    if choice then
      callback(choice.id, choice.path)
    end
  end)
end

function M.get_doc_by_id(doc_id)
  for _, doc in ipairs(M._project_tree) do
    if doc.id == doc_id then
      return doc
    end
  end
  return nil
end

function M.get_doc_by_path(path)
  for _, doc in ipairs(M._project_tree) do
    if doc.path == path then
      return doc
    end
  end
  return nil
end

--- Check if a path already exists in the tree
function M.path_exists(path)
  for _, entry in ipairs(M._project_tree) do
    if entry.path == path then
      return true
    end
  end
  return false
end

--- Add an entry to the tree (for after API create calls), dedup by ID
function M.add_entry(entry)
  for _, existing in ipairs(M._project_tree) do
    if existing.id == entry.id then
      return false -- already exists
    end
  end
  table.insert(M._project_tree, entry)
  return true
end

--- Rename an entry in the tree
function M.rename_entry(entity_id, new_name)
  for _, entry in ipairs(M._project_tree) do
    if entry.id == entity_id then
      local old_name = entry.name
      entry.name = new_name
      -- Update path: replace the last component
      if entry.type == 'folder' then
        local old_path = entry.path
        local parent = old_path:match('^(.-)' .. vim.pesc(old_name) .. '/$') or ''
        local new_path = parent .. new_name .. '/'
        entry.path = new_path
        -- Update all children whose path starts with old_path
        for _, child in ipairs(M._project_tree) do
          if child ~= entry and child.path:sub(1, #old_path) == old_path then
            child.path = new_path .. child.path:sub(#old_path + 1)
          end
        end
      else
        local parent = entry.path:match('^(.*/)') or ''
        entry.path = parent .. new_name
      end
      return entry
    end
  end
  return nil
end

--- Update an entry's ID (used for file-restore where the doc gets a new _id)
function M.update_entry_id(old_id, new_id)
  for _, entry in ipairs(M._project_tree) do
    if entry.id == old_id then
      entry.id = new_id
      return entry
    end
  end
  return nil
end

--- Remove an entry from the tree by ID
function M.remove_entry(entity_id)
  for i, entry in ipairs(M._project_tree) do
    if entry.id == entity_id then
      table.remove(M._project_tree, i)
      return true
    end
  end
  return false
end

--- Get the path prefix for a parent folder
function M.get_folder_path(folder_id)
  if not folder_id then return '' end
  for _, entry in ipairs(M._project_tree) do
    if entry.id == folder_id and entry.type == 'folder' then
      return entry.path
    end
  end
  return ''
end

return M
